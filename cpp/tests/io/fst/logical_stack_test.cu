/*
 * Copyright (c) 2022, NVIDIA CORPORATION.
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

#include <cudf_test/base_fixture.hpp>
#include <cudf_test/cudf_gtest.hpp>

#include <io/utilities/hostdevice_vector.hpp>
#include <src/io/fst/logical_stack.cuh>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_uvector.hpp>

#include <cstdlib>
#include <iostream>
#include <iterator>
#include <stack>
#include <vector>

namespace {
namespace fst = cudf::io::fst;

/**
 * @brief Generates the sparse representation of stack operations to feed into the logical
 * stack
 *
 * @param begin Forward input iterator to the first item of symbols that are checked for whether
 * they push or pop
 * @param end Forward input iterator to one one past the last item of symbols that are checked for
 * whether they push or pop
 * @param to_stack_op A function object that takes an instance of InputItT's value type and
 * returns the kind of stack operation such item represents (i.e., of type stack_op_type)
 * @param stack_symbol_out Forward output iterator to which symbols that either push or pop are
 * assigned
 * @param stack_op_index_out Forward output iterator to which the indexes of symbols that either
 * push or pop are assigned
 * @return Pair of iterators to one past the last item of the items written to \p stack_symbol_out
 * and \p stack_op_index_out, respectively
 */
template <typename InputItT,
          typename ToStackOpTypeT,
          typename StackSymbolOutItT,
          typename StackOpIndexOutItT>
std::pair<StackSymbolOutItT, StackOpIndexOutItT> to_sparse_stack_symbols(
  InputItT begin,
  InputItT end,
  ToStackOpTypeT to_stack_op,
  StackSymbolOutItT stack_symbol_out,
  StackOpIndexOutItT stack_op_index_out)
{
  std::size_t index = 0;
  for (auto it = begin; it < end; it++) {
    fst::stack_op_type op_type = to_stack_op(*it);
    if (op_type == fst::stack_op_type::PUSH || op_type == fst::stack_op_type::POP) {
      *stack_symbol_out   = *it;
      *stack_op_index_out = index;
      stack_symbol_out++;
      stack_op_index_out++;
    }
    index++;
  }
  return std::make_pair(stack_symbol_out, stack_op_index_out);
}

/**
 * @brief Reads in a sequence of items that represent stack operations, applies these operations to
 * a stack, and, for every oepration being read in, outputs what was the symbol on top of the stack
 * before the operations was applied. In case the stack is empty before any operation,
 * \p empty_stack will be output instead.
 *
 * @tparam InputItT Forward input iterator type to items representing stack operations
 * @tparam ToStackOpTypeT A transform function object class that maps an item representing a stack
 * oepration to the stack_op_type of such item
 * @tparam StackSymbolT Type representing items being pushed onto the stack
 * @tparam TopOfStackOutItT A forward output iterator type being assigned items of StackSymbolT
 * @param[in] begin Forward iterator to the beginning of the items representing stack operations
 * @param[in] end Iterator to one past the last item representing the stack operation
 * @param[in] to_stack_op A function object that takes an instance of InputItT's value type and
 * returns the kind of stack operation such item represents (i.e., of type stack_op_type)
 * @param[in] empty_stack A symbol that will be written to top_of_stack whenever the stack was empty
 * @param[out] top_of_stack The output iterator to which the item will be written to
 * @return TopOfStackOutItT Iterators to one past the last element that was written
 */
template <typename InputItT,
          typename ToStackOpTypeT,
          typename StackSymbolT,
          typename TopOfStackOutItT>
TopOfStackOutItT to_top_of_stack(InputItT begin,
                                 InputItT end,
                                 ToStackOpTypeT to_stack_op,
                                 StackSymbolT empty_stack,
                                 TopOfStackOutItT top_of_stack)
{
  std::stack<StackSymbolT> stack;
  for (auto it = begin; it < end; it++) {
    // Write what is currently on top of the stack when reading in the current symbol
    *top_of_stack = stack.empty() ? empty_stack : stack.top();
    top_of_stack++;

    auto const& current        = *it;
    fst::stack_op_type op_type = to_stack_op(current);

    // Check whether this symbol corresponds to a push or pop operation and modify the stack
    // accordingly
    if (op_type == fst::stack_op_type::PUSH) {
      stack.push(current);
    } else if (op_type == fst::stack_op_type::POP) {
      stack.pop();
    }
  }
  return top_of_stack;
}

/**
 * @brief Funciton object used to filter for brackets and braces that represent push and pop
 * operations
 *
 */
struct JSONToStackOp {
  template <typename StackSymbolT>
  __host__ __device__ __forceinline__ fst::stack_op_type operator()(
    StackSymbolT const& stack_symbol) const
  {
    return (stack_symbol == '{' || stack_symbol == '[')   ? fst::stack_op_type::PUSH
           : (stack_symbol == '}' || stack_symbol == ']') ? fst::stack_op_type::POP
                                                          : fst::stack_op_type::READ;
  }
};
}  // namespace


// Base test fixture for tests
struct LogicalStackTest : public cudf::test::BaseFixture {
};

TEST_F(LogicalStackTest, GroundTruth)
{
  // Type sufficient to cover any stack level (must be a signed type)
  using StackLevelT   = int8_t;
  using SymbolT       = char;
  using SymbolOffsetT = uint32_t;

  // The stack symbol that we'll fill everywhere where there's nothing on the stack
  constexpr SymbolT empty_stack_symbol = '_';

  // This just has to be a stack symbol that may not be confused with a symbol that would push or
  // pop
  constexpr SymbolT read_symbol = 'x';

  // Prepare cuda stream for data transfers & kernels
  cudaStream_t stream = nullptr;
  cudaStreamCreate(&stream);
  rmm::cuda_stream_view stream_view(stream);

  // Test input,
  std::string input = R"(  {
"category": "reference",
"index:" [4,12,42],
"author": "Nigel Rees",
"title": "Sayings of the Century",
"price": 8.95
}  
{
"category": "reference",
"index:" [4,{},null,{"a":[]}],
"author": "Nigel Rees",
"title": "Sayings of the Century",
"price": 8.95
}  )";

  // Repeat input sample 1024x 
  for (std::size_t i = 0; i < 10; i++)
    input += input;

  // Getting the symbols that actually modify the stack (i.e., symbols that push or pop)
  std::string stack_symbols = "";
  std::vector<SymbolOffsetT> stack_op_indexes;
  stack_op_indexes.reserve(input.size());

  // Get the sparse representation of stack operations
  to_sparse_stack_symbols(std::cbegin(input),
                          std::cend(input),
                          JSONToStackOp{},
                          std::back_inserter(stack_symbols),
                          std::back_inserter(stack_op_indexes));

  // Prepare sparse stack ops
  std::size_t num_stack_ops = stack_symbols.size();

  rmm::device_uvector<SymbolT> d_stack_ops(stack_symbols.size(), stream_view);
  rmm::device_uvector<SymbolOffsetT> d_stack_op_indexes(stack_op_indexes.size(), stream_view);
  auto top_of_stack_gpu = hostdevice_vector<SymbolT>(input.size(), stream_view);

  cudaMemcpyAsync(d_stack_ops.data(),
                  stack_symbols.data(),
                  stack_symbols.size() * sizeof(SymbolT),
                  cudaMemcpyHostToDevice,
                  stream);

  cudaMemcpyAsync(d_stack_op_indexes.data(),
                  stack_op_indexes.data(),
                  stack_op_indexes.size() * sizeof(SymbolOffsetT),
                  cudaMemcpyHostToDevice,
                  stream);

  // Prepare output
  std::size_t string_size = input.size();
  SymbolT* d_top_of_stack = nullptr;
  cudaMalloc(&d_top_of_stack, string_size + 1);

  // Request temporary storage requirements
  std::size_t temp_storage_bytes = 0;
  fst::SparseStackOpToTopOfStack<StackLevelT>(nullptr,
                                              temp_storage_bytes,
                                              d_stack_ops.data(),
                                              d_stack_op_indexes.data(),
                                              JSONToStackOp{},
                                              d_top_of_stack,
                                              empty_stack_symbol,
                                              read_symbol,
                                              num_stack_ops,
                                              string_size,
                                              stream);

  // Allocate temporary storage required by the get-top-of-the-stack algorithm
  rmm::device_buffer d_temp_storage(temp_storage_bytes, stream_view);

  // Run algorithm
  fst::SparseStackOpToTopOfStack<StackLevelT>(d_temp_storage.data(),
                                              temp_storage_bytes,
                                              d_stack_ops.data(),
                                              d_stack_op_indexes.data(),
                                              JSONToStackOp{},
                                              top_of_stack_gpu.device_ptr(),
                                              empty_stack_symbol,
                                              read_symbol,
                                              num_stack_ops,
                                              string_size,
                                              stream);

  // Async copy results from device to host
  top_of_stack_gpu.device_to_host(stream_view);

  // Get CPU-side results for verification
  std::string top_of_stack_cpu{};
  top_of_stack_cpu.reserve(input.size());
  to_top_of_stack(std::cbegin(input),
                  std::cend(input),
                  JSONToStackOp{},
                  empty_stack_symbol,
                  std::back_inserter(top_of_stack_cpu));

  // Make sure results have been copied back to host
  cudaStreamSynchronize(stream);

  // Verify results
  ASSERT_EQ(input.size(), top_of_stack_cpu.size());
  for (size_t i = 0; i < input.size() && i < top_of_stack_cpu.size(); i++) {
    ASSERT_EQ(top_of_stack_gpu.host_ptr()[i], top_of_stack_cpu[i]) << "Mismatch at index #" << i;
  }
}

CUDF_TEST_PROGRAM_MAIN()
