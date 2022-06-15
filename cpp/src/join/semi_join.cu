/*
 * Copyright (c) 2020-2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <join/join_common_utils.cuh>
#include <join/join_common_utils.hpp>

#include <cudf/column/column_factories.hpp>
#include <cudf/detail/gather.hpp>
#include <cudf/detail/iterator.cuh>
#include <cudf/detail/null_mask.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/dictionary/detail/update_keys.hpp>
#include <cudf/join.hpp>
#include <cudf/table/experimental/row_operators.cuh>
#include <cudf/table/table.hpp>
#include <cudf/utilities/error.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_uvector.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/copy.h>
#include <thrust/distance.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/sequence.h>
#include <thrust/transform.h>
#include <thrust/tuple.h>

#include <cooperative_groups.h>

namespace cudf {
namespace detail {

namespace {

using cudf::experimental::row::lhs_index_type;
using cudf::experimental::row::rhs_index_type;

using nan_equal_comparator =
  cudf::experimental::row::equality::nan_equal_physical_equality_comparator;
using nan_unequal_comparator = cudf::experimental::row::equality::physical_equality_comparator;

/**
 * @brief Device functor to create a pair of hash value and index for a given row.
 * @tparam T Type of the index, must be `size_type` or a strong index type.
 * @tparam Hasher The functor type to compute row hash.
 */
template <typename T, typename Hasher>
struct make_pair_fn {
  Hasher const hasher;
  hash_value_type const empty_key_sentinel;

  __device__ inline auto operator()(size_type const i) const noexcept
  {
    auto const hash_value = remap_sentinel_hash(hasher(i), empty_key_sentinel);
    return cuco::make_pair(hash_value, T{i});
  }
};

/**
 * @brief The functor to compare two pairs of values with row equality comparison.
 *
 * @tparam Comparator The row comparator type to perform row equality comparison.
 */
template <typename Comparator>
struct pair_comparator_fn {
  Comparator const d_eqcomp;

  template <typename LHSPair, typename RHSPair>
  __device__ inline bool operator()(LHSPair const& lhs_hash_and_index,
                                    RHSPair const& rhs_hash_and_index) const noexcept
  {
    auto const& [lhs_hash, lhs_index] = lhs_hash_and_index;
    auto const& [rhs_hash, rhs_index] = rhs_hash_and_index;
    return lhs_hash == rhs_hash ? d_eqcomp(lhs_index, rhs_index) : false;
  }
};

template <typename MapView, typename KV, typename Comparator>
struct check_contains {
  MapView d_map;
  KV const kv_pair;
  bitmask_type const* bitmask;
  Comparator const dcomp;

  __device__ bool operator()(size_type i)
  {
    auto idx = i / DEFAULT_JOIN_CG_SIZE;
    if (!cudf::bit_is_set(bitmask, idx)) { return false; }

    auto const tile = cooperative_groups::tiled_partition<DEFAULT_JOIN_CG_SIZE>(
      cooperative_groups::this_thread_block());
    return d_map.pair_contains(tile, *(kv_pair + idx), dcomp);
  }
};

// template <typename MapView, typename KV, typename Comparator>
// struct check_contains {
//  MapView d_map;
//  KV const kv_pair;
//  Comparator const dcomp;

//  __device__ bool operator()(size_type i)
//  {
//    auto idx        = i / DEFAULT_JOIN_CG_SIZE;
//    auto const tile = cooperative_groups::tiled_partition<DEFAULT_JOIN_CG_SIZE>(
//      cooperative_groups::this_thread_block());
//    return d_map.pair_contains(tile, *(kv_pair + idx), dcomp);
//  }
//};

struct copy_no_duplicate {
  bool const* const contained_tmp;
  __device__ bool operator()(size_type idx) const { return contained_tmp[idx * 2]; }
};

/**
 * @brief The functor to accumulate all nullable columns at all nested levels from a given column.
 *
 * This is to avoid expensive materializing the bitmask into a real column when calling to
 * `structs::detail::flatten_nested_columns`.
 */
void accumulate_nullable_nested_columns(column_view const& col, std::vector<column_view>& result)
{
  if (col.nullable()) { result.push_back(col); }

  for (auto it = col.child_begin(); it != col.child_end(); ++it) {
    auto const& child = *it;
    if (child.size() == col.size()) { accumulate_nullable_nested_columns(child, result); }
  }
}

}  // namespace

rmm::device_uvector<bool> left_semi_join_contains(table_view const& left_keys,
                                                  table_view const& right_keys,
                                                  null_equality compare_nulls,
                                                  nan_equality compare_nans,
                                                  rmm::cuda_stream_view stream,
                                                  rmm::mr::device_memory_resource* mr)
{
  // Use a hash map with key type is row hash values and map value type is `rhs_index_type` to store
  // all indices of row in the rhs table.
  using hash_map_type =
    cuco::static_multimap<hash_value_type,
                          rhs_index_type,
                          cuda::thread_scope_device,
                          rmm::mr::stream_allocator_adaptor<default_allocator<char>>,
                          cuco::double_hashing<DEFAULT_JOIN_CG_SIZE, hash_type, hash_type>>;

  auto map = hash_map_type(compute_hash_table_size(right_keys.num_rows()),
                           cuco::sentinel::empty_key{std::numeric_limits<hash_value_type>::max()},
                           cuco::sentinel::empty_value{rhs_index_type{cudf::detail::JoinNoneValue}},
                           stream.value(),
                           detail::hash_table_allocator_type{default_allocator<char>{}, stream});

  auto const lhs_has_nulls = has_nested_nulls(left_keys);
  auto const rhs_has_nulls = has_nested_nulls(right_keys);

  // Insert all row hash values and indices of the rhs table.
  {
    auto const hasher   = cudf::experimental::row::hash::row_hasher(right_keys, stream);
    auto const d_hasher = hasher.device_hasher(nullate::DYNAMIC{rhs_has_nulls});

    auto const kv_it = cudf::detail::make_counting_transform_iterator(
      size_type{0},
      make_pair_fn<rhs_index_type, decltype(d_hasher)>{d_hasher, map.get_empty_key_sentinel()});

    // If right table has nulls but they are compared unequal, don't insert them.
    // Otherwise, it was known to cause performance issue:
    // - https://github.com/rapidsai/cudf/pull/6943
    // - https://github.com/rapidsai/cudf/pull/8277
    if (rhs_has_nulls && compare_nulls == null_equality::UNEQUAL) {
      // Gather all nullable columns at all levels from the right table.
      auto const right_nullable_columns = [&] {
        auto result = std::vector<column_view>{};
        for (auto const& col : right_keys) {
          accumulate_nullable_nested_columns(col, result);
        }
        return result;
      }();

      [[maybe_unused]] auto const [row_bitmask, tmp] =
        cudf::detail::bitmask_and(table_view{right_nullable_columns}, stream);

      // Insert only rows that do not have any nulls at any level.
      map.insert_if(kv_it,
                    kv_it + right_keys.num_rows(),
                    thrust::counting_iterator<size_type>(0),  // stencil
                    row_is_valid{static_cast<bitmask_type const*>(row_bitmask.data())},
                    stream.value());
    } else {
      map.insert(kv_it, kv_it + right_keys.num_rows(), stream.value());
    }
  }

  auto contained = rmm::device_uvector<bool>(left_keys.num_rows(), stream);

  // Check contains for each row of the lhs table in the rhs table.
  {
    auto const hasher   = cudf::experimental::row::hash::row_hasher(left_keys, stream);
    auto const d_hasher = hasher.device_hasher(nullate::DYNAMIC{lhs_has_nulls});

    auto const kv_it = cudf::detail::make_counting_transform_iterator(
      size_type{0},
      make_pair_fn<lhs_index_type, decltype(d_hasher)>{d_hasher, map.get_empty_key_sentinel()});

    auto const comparator =
      cudf::experimental::row::equality::two_table_comparator(left_keys, right_keys, stream);

    auto const do_check = [&](auto const& value_comp) {
      auto const d_eqcomp = comparator.equal_to(
        nullate::DYNAMIC{lhs_has_nulls || rhs_has_nulls}, compare_nulls, value_comp);

      if (lhs_has_nulls && compare_nulls == null_equality::UNEQUAL) {
        // Gather all nullable columns at all levels from the left table.
        auto const left_nullable_columns = [&] {
          auto result = std::vector<column_view>{};
          for (auto const& col : left_keys) {
            accumulate_nullable_nested_columns(col, result);
          }
          return result;
        }();

        [[maybe_unused]] auto const [row_bitmask, tmp] =
          cudf::detail::bitmask_and(table_view{left_nullable_columns}, stream);

        auto d_map           = map.get_device_view();
        auto const pair_comp = pair_comparator_fn<decltype(d_eqcomp)>{d_eqcomp};

        auto contained_tmp =
          rmm::device_uvector<bool>(left_keys.num_rows() * DEFAULT_JOIN_CG_SIZE, stream);
        thrust::transform(
          rmm::exec_policy(stream),
          thrust::make_counting_iterator(0),
          thrust::make_counting_iterator(left_keys.num_rows() * DEFAULT_JOIN_CG_SIZE),
          contained_tmp.begin(),
          check_contains<decltype(d_map), decltype(kv_it), decltype(pair_comp)>{
            d_map, kv_it, static_cast<bitmask_type const*>(row_bitmask.data()), pair_comp});

        thrust::transform(rmm::exec_policy(stream),
                          thrust::make_counting_iterator(0),
                          thrust::make_counting_iterator(left_keys.num_rows()),
                          contained.begin(),
                          copy_no_duplicate{contained_tmp.begin()});
      } else {
        map.pair_contains(kv_it,
                          kv_it + left_keys.num_rows(),
                          contained.begin(),
                          pair_comparator_fn<decltype(d_eqcomp)>{d_eqcomp},
                          stream.value());
      }
    };

    if (compare_nans == nan_equality::ALL_EQUAL) {
      do_check(nan_equal_comparator{});
    } else {
      do_check(nan_unequal_comparator{});
    }
  }

  return contained;
}

std::unique_ptr<rmm::device_uvector<cudf::size_type>> left_semi_anti_join(
  join_kind const kind,
  cudf::table_view const& left_keys,
  cudf::table_view const& right_keys,
  null_equality compare_nulls,
  rmm::cuda_stream_view stream,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource())
{
  CUDF_EXPECTS(0 != left_keys.num_columns(), "Left table is empty");
  CUDF_EXPECTS(0 != right_keys.num_columns(), "Right table is empty");

  if (is_trivial_join(left_keys, right_keys, kind)) {
    return std::make_unique<rmm::device_uvector<cudf::size_type>>(0, stream, mr);
  }
  if ((join_kind::LEFT_ANTI_JOIN == kind) && (0 == right_keys.num_rows())) {
    auto result =
      std::make_unique<rmm::device_uvector<cudf::size_type>>(left_keys.num_rows(), stream, mr);
    thrust::sequence(rmm::exec_policy(stream), result->begin(), result->end());
    return result;
  }

  auto const flagged = [&] {
    // Use `nan_equality::UNEQUAL` as the default value for comparing NaNs in semi- and anti- joins.
    auto contained =
      left_semi_join_contains(left_keys, right_keys, compare_nulls, nan_equality::UNEQUAL, stream);
    if (kind == join_kind::LEFT_ANTI_JOIN) {
      thrust::transform(rmm::exec_policy(stream),
                        contained.begin(),
                        contained.end(),
                        contained.begin(),
                        thrust::logical_not{});
    }
    return contained;
  }();

  auto const left_num_rows = left_keys.num_rows();
  auto gather_map =
    std::make_unique<rmm::device_uvector<cudf::size_type>>(left_num_rows, stream, mr);

  // gather_map_end will be the end of valid data in gather_map
  auto gather_map_end = thrust::copy_if(
    rmm::exec_policy(stream),
    thrust::counting_iterator<size_type>(0),
    thrust::counting_iterator<size_type>(left_num_rows),
    gather_map->begin(),
    [d_flagged = flagged.begin()] __device__(size_type const idx) { return d_flagged[idx]; });

  gather_map->resize(thrust::distance(gather_map->begin(), gather_map_end), stream);
  return gather_map;
}

/**
 * @brief  Performs a left semi or anti join on the specified columns of two
 * tables (left, right)
 *
 * The semi and anti joins only return data from the left table. A left semi join
 * returns rows that exist in the right table, a left anti join returns rows
 * that do not exist in the right table.
 *
 * The basic approach is to create a hash table containing the contents of the right
 * table and then select only rows that exist (or don't exist) to be included in
 * the return set.
 *
 * @throws cudf::logic_error if number of columns in either `left` or `right` table is 0
 * @throws cudf::logic_error if number of returned columns is 0
 * @throws cudf::logic_error if number of elements in `right_on` and `left_on` are not equal
 *
 * @param kind          Indicates whether to do LEFT_SEMI_JOIN or LEFT_ANTI_JOIN
 * @param left          The left table
 * @param right         The right table
 * @param left_on       The column indices from `left` to join on.
 *                      The column from `left` indicated by `left_on[i]`
 *                      will be compared against the column from `right`
 *                      indicated by `right_on[i]`.
 * @param right_on      The column indices from `right` to join on.
 *                      The column from `right` indicated by `right_on[i]`
 *                      will be compared against the column from `left`
 *                      indicated by `left_on[i]`.
 * @param compare_nulls Controls whether null join-key values should match or not.
 * @param stream        CUDA stream used for device memory operations and kernel launches.
 * @param mr            Device memory resource to used to allocate the returned table
 *
 * @returns             Result of joining `left` and `right` tables on the columns
 *                      specified by `left_on` and `right_on`.
 */
std::unique_ptr<cudf::table> left_semi_anti_join(
  join_kind const kind,
  cudf::table_view const& left,
  cudf::table_view const& right,
  std::vector<cudf::size_type> const& left_on,
  std::vector<cudf::size_type> const& right_on,
  null_equality compare_nulls,
  rmm::cuda_stream_view stream,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource())
{
  CUDF_EXPECTS(left_on.size() == right_on.size(), "Mismatch in number of columns to be joined on");

  if ((left_on.empty() || right_on.empty()) || is_trivial_join(left, right, kind)) {
    return empty_like(left);
  }

  if ((join_kind::LEFT_ANTI_JOIN == kind) && (0 == right.num_rows())) {
    // Everything matches, just copy the proper columns from the left table
    return std::make_unique<table>(left, stream, mr);
  }

  // Make sure any dictionary columns have matched key sets.
  // This will return any new dictionary columns created as well as updated table_views.
  auto matched = cudf::dictionary::detail::match_dictionaries(
    {left.select(left_on), right.select(right_on)},
    stream,
    rmm::mr::get_current_device_resource());  // temporary objects returned

  auto const left_selected  = matched.second.front();
  auto const right_selected = matched.second.back();

  auto gather_vector =
    left_semi_anti_join(kind, left_selected, right_selected, compare_nulls, stream);

  // wrapping the device vector with a column view allows calling the non-iterator
  // version of detail::gather, improving compile time by 10% and reducing the
  // object file size by 2.2x without affecting performance
  auto gather_map = column_view(data_type{type_id::INT32},
                                static_cast<size_type>(gather_vector->size()),
                                gather_vector->data(),
                                nullptr,
                                0);

  auto const left_updated = scatter_columns(left_selected, left_on, left);
  return cudf::detail::gather(left_updated,
                              gather_map,
                              out_of_bounds_policy::DONT_CHECK,
                              negative_index_policy::NOT_ALLOWED,
                              stream,
                              mr);
}

}  // namespace detail

std::unique_ptr<cudf::table> left_semi_join(cudf::table_view const& left,
                                            cudf::table_view const& right,
                                            std::vector<cudf::size_type> const& left_on,
                                            std::vector<cudf::size_type> const& right_on,
                                            null_equality compare_nulls,
                                            rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  return detail::left_semi_anti_join(detail::join_kind::LEFT_SEMI_JOIN,
                                     left,
                                     right,
                                     left_on,
                                     right_on,
                                     compare_nulls,
                                     rmm::cuda_stream_default,
                                     mr);
}

std::unique_ptr<rmm::device_uvector<cudf::size_type>> left_semi_join(
  cudf::table_view const& left,
  cudf::table_view const& right,
  null_equality compare_nulls,
  rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  return detail::left_semi_anti_join(
    detail::join_kind::LEFT_SEMI_JOIN, left, right, compare_nulls, rmm::cuda_stream_default, mr);
}

std::unique_ptr<cudf::table> left_anti_join(cudf::table_view const& left,
                                            cudf::table_view const& right,
                                            std::vector<cudf::size_type> const& left_on,
                                            std::vector<cudf::size_type> const& right_on,
                                            null_equality compare_nulls,
                                            rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  return detail::left_semi_anti_join(detail::join_kind::LEFT_ANTI_JOIN,
                                     left,
                                     right,
                                     left_on,
                                     right_on,
                                     compare_nulls,
                                     rmm::cuda_stream_default,
                                     mr);
}

std::unique_ptr<rmm::device_uvector<cudf::size_type>> left_anti_join(
  cudf::table_view const& left,
  cudf::table_view const& right,
  null_equality compare_nulls,
  rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  return detail::left_semi_anti_join(
    detail::join_kind::LEFT_ANTI_JOIN, left, right, compare_nulls, rmm::cuda_stream_default, mr);
}

}  // namespace cudf
