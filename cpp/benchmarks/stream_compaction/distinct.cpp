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

#include <benchmarks/common/generate_input.hpp>
#include <benchmarks/fixture/rmm_pool_raii.hpp>

#include <cudf/column/column_view.hpp>
#include <cudf/detail/stream_compaction.hpp>
#include <cudf/lists/list_view.hpp>
#include <cudf/types.hpp>

#include <nvbench/nvbench.cuh>

NVBENCH_DECLARE_TYPE_STRINGS(cudf::timestamp_ms, "cudf::timestamp_ms", "cudf::timestamp_ms");

template <typename Type>
void nvbench_distinct(nvbench::state& state, nvbench::type_list<Type>)
{
  cudf::rmm_pool_raii pool_raii;

  cudf::size_type const num_rows = state.get_int64("NumRows");

  data_profile profile;
  profile.set_null_frequency(0.01);
  profile.set_cardinality(0);
  profile.set_distribution_params<Type>(cudf::type_to_id<Type>(), distribution_id::UNIFORM, 0, 100);

  auto source_table =
    create_random_table(cycle_dtypes({cudf::type_to_id<Type>()}, 1), row_count{num_rows}, profile);

  auto input_column = cudf::column_view(source_table->get_column(0));
  auto input_table  = cudf::table_view({input_column, input_column, input_column, input_column});

  state.exec(nvbench::exec_tag::sync, [&](nvbench::launch& launch) {
    rmm::cuda_stream_view stream_view{launch.get_stream()};
    auto result = cudf::detail::distinct(input_table,
                                         {0},
                                         cudf::duplicate_keep_option::KEEP_ANY,
                                         cudf::null_equality::EQUAL,
                                         cudf::nan_equality::ALL_EQUAL,
                                         stream_view);
  });
}

using data_type = nvbench::type_list<bool, int8_t, int32_t, int64_t, float, cudf::timestamp_ms>;

NVBENCH_BENCH_TYPES(nvbench_distinct, NVBENCH_TYPE_AXES(data_type))
  .set_name("distinct")
  .set_type_axes_names({"Type"})
  .add_int64_axis("NumRows", {10'000, 100'000, 1'000'000, 10'000'000});

template <typename Type>
void nvbench_distinct_list(nvbench::state& state, nvbench::type_list<Type>)
{
  cudf::rmm_pool_raii pool_raii;

  auto const size             = state.get_int64("ColumnSize");
  auto const dtype            = cudf::type_to_id<Type>();
  double const null_frequency = state.get_float64("null_frequency");

  data_profile table_data_profile;
  if (dtype == cudf::type_id::LIST) {
    table_data_profile.set_distribution_params(dtype, distribution_id::UNIFORM, 0, 4);
    table_data_profile.set_distribution_params(
      cudf::type_id::INT32, distribution_id::UNIFORM, 0, 4);
    table_data_profile.set_list_depth(1);
  } else {
    // We're comparing distinct() on a non-nested column to that on a list column with the same
    // number of distinct rows. The max list size is 4 and the number of distinct values in the
    // list's child is 5. So the number of distinct rows in the list = 1 + 5 + 5^2 + 5^3 + 5^4 = 781
    // We want this column to also have 781 distinct values.
    table_data_profile.set_distribution_params(dtype, distribution_id::UNIFORM, 0, 781);
  }
  table_data_profile.set_null_frequency(null_frequency);

  auto const table = create_random_table(
    {dtype}, table_size_bytes{static_cast<size_t>(size)}, table_data_profile, 0);

  state.exec(nvbench::exec_tag::sync, [&](nvbench::launch& launch) {
    rmm::cuda_stream_view stream_view{launch.get_stream()};
    auto result = cudf::detail::distinct(*table,
                                         {0},
                                         cudf::duplicate_keep_option::KEEP_ANY,
                                         cudf::null_equality::EQUAL,
                                         cudf::nan_equality::ALL_EQUAL,
                                         stream_view);
  });
}

NVBENCH_BENCH_TYPES(nvbench_distinct_list,
                    NVBENCH_TYPE_AXES(nvbench::type_list<int32_t, cudf::list_view>))
  .set_name("distinct_list")
  .set_type_axes_names({"Type"})
  .add_float64_axis("null_frequency", {0.0, 0.1})
  .add_int64_axis("ColumnSize", {100'000'000});
