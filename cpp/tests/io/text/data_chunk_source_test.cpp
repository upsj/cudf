/*
 * Copyright (c) 2021-2022, NVIDIA CORPORATION.
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

#include "io/text/bgzip_utils.hpp"

#include <cudf/io/text/data_chunk_source_factories.hpp>

#include <rmm/cuda_stream_view.hpp>

#include <fstream>
#include <random>

using namespace cudf::test;

auto const temp_env = static_cast<TempDirTestEnvironment*>(
  ::testing::AddGlobalTestEnvironment(new TempDirTestEnvironment));

struct DataChunkSourceTest : public BaseFixture {
};

std::string chunk_to_host(const cudf::io::text::device_data_chunk& chunk)
{
  std::string result(chunk.size(), '\0');
  cudaMemcpy(result.data(), chunk.data(), chunk.size(), cudaMemcpyDeviceToHost);
  return result;
}

void test_source(const std::string& content, const cudf::io::text::data_chunk_source& source)
{
  {
    // full contents
    auto reader      = source.create_reader();
    auto const chunk = reader->get_next_chunk(content.size(), rmm::cuda_stream_default);
    ASSERT_EQ(chunk->size(), content.size());
    ASSERT_EQ(chunk_to_host(*chunk), content);
  }
  {
    // skipping contents
    auto reader = source.create_reader();
    reader->skip_bytes(4);
    auto const chunk = reader->get_next_chunk(content.size(), rmm::cuda_stream_default);
    ASSERT_EQ(chunk->size(), content.size() - 4);
    ASSERT_EQ(chunk_to_host(*chunk), content.substr(4));
  }
  {
    // reading multiple chunks, starting with a small one
    auto reader       = source.create_reader();
    auto const chunk1 = reader->get_next_chunk(5, rmm::cuda_stream_default);
    auto const chunk2 = reader->get_next_chunk(content.size() - 5, rmm::cuda_stream_default);
    ASSERT_EQ(chunk1->size(), 5);
    ASSERT_EQ(chunk2->size(), content.size() - 5);
    ASSERT_EQ(chunk_to_host(*chunk1), content.substr(0, 5));
    ASSERT_EQ(chunk_to_host(*chunk2), content.substr(5));
  }
  {
    // reading multiple chunks
    auto reader       = source.create_reader();
    auto const chunk1 = reader->get_next_chunk(content.size() / 2, rmm::cuda_stream_default);
    auto const chunk2 =
      reader->get_next_chunk(content.size() - content.size() / 2, rmm::cuda_stream_default);
    ASSERT_EQ(chunk1->size(), content.size() / 2);
    ASSERT_EQ(chunk2->size(), content.size() - content.size() / 2);
    ASSERT_EQ(chunk_to_host(*chunk1), content.substr(0, content.size() / 2));
    ASSERT_EQ(chunk_to_host(*chunk2), content.substr(content.size() / 2));
  }
  {
    // reading too many bytes
    auto reader      = source.create_reader();
    auto const chunk = reader->get_next_chunk(content.size() + 10, rmm::cuda_stream_default);
    ASSERT_EQ(chunk->size(), content.size());
    ASSERT_EQ(chunk_to_host(*chunk), content);
    auto next_chunk = reader->get_next_chunk(1, rmm::cuda_stream_default);
    ASSERT_EQ(next_chunk->size(), 0);
  }
  {
    // skipping past the end
    auto reader = source.create_reader();
    reader->skip_bytes(content.size() + 10);
    auto const next_chunk = reader->get_next_chunk(1, rmm::cuda_stream_default);
    ASSERT_EQ(next_chunk->size(), 0);
  }
}

TEST_F(DataChunkSourceTest, Device)
{
  std::string const content = "device buffer source";
  cudf::string_scalar scalar(content);
  auto const source = cudf::io::text::make_source(scalar);

  test_source(content, *source);
}

TEST_F(DataChunkSourceTest, File)
{
  std::string const content = "file source";
  auto const filename       = temp_env->get_temp_filepath("file_source");
  {
    std::ofstream file{filename};
    file << content;
  }
  auto const source = cudf::io::text::make_source_from_file(filename);

  test_source(content, *source);
}

TEST_F(DataChunkSourceTest, Host)
{
  std::string const content = "host buffer source";
  auto const source         = cudf::io::text::make_source(content);

  test_source(content, *source);
}

void write_bgzip(std::ostream& stream,
                 const std::string& data,
                 std::default_random_engine& rng,
                 bool compress,
                 bool write_eof)
{
  std::vector<char> const extra_garbage_field1{{13,  // magic number
                                                37,  // magic number
                                                7,   // field length
                                                0,   // field length
                                                1,
                                                2,
                                                3,
                                                4,
                                                5,
                                                6,
                                                7}};
  std::vector<char> const extra_garbage_field2{{12,  // magic number
                                                34,  // magic number
                                                2,   // field length
                                                0,   // field length
                                                1,  2,
                                                56,  // magic number
                                                78,  // magic number
                                                1,   // field length
                                                0,   // field length
                                                3,   //
                                                90,  // magic number
                                                12,  // magic number
                                                8,   // field length
                                                0,   // field length
                                                1,  2, 3, 4, 5, 6, 7, 8}};
  // make sure the block size with header stays below 65536
  std::uniform_int_distribution<std::size_t> block_size_dist{1, 65000};
  auto begin     = data.data();
  auto const end = data.data() + data.size();
  int i          = 0;
  while (begin < end) {
    using cudf::host_span;
    auto len = std::min<std::size_t>(end - begin, block_size_dist(rng));
    host_span<char const> const garbage_before =
      i & 1 ? extra_garbage_field1 : host_span<char const>{};
    host_span<char const> const garbage_after =
      i & 2 ? extra_garbage_field2 : host_span<char const>{};
    if (compress) {
      cudf::io::text::detail::bgzip::write_compressed_block(
        stream, {begin, len}, garbage_before, garbage_after);
    } else {
      cudf::io::text::detail::bgzip::write_uncompressed_block(
        stream, {begin, len}, garbage_before, garbage_after);
    }
    begin += len;
    i++;
  }
  if (write_eof) { cudf::io::text::detail::bgzip::write_uncompressed_block(stream, {}); }
}

TEST_F(DataChunkSourceTest, BgzipSource)
{
  auto const filename = temp_env->get_temp_filepath("bgzip_source");
  std::string input{"bananarama"};
  for (int i = 0; i < 24; i++) {
    input = input + input;
  }
  {
    std::ofstream stream{filename};
    std::default_random_engine rng{};
    write_bgzip(stream, input, rng, false, true);
  }

  auto const source = cudf::io::text::make_source_from_bgzip_file(filename);

  test_source(input, *source);
}

TEST_F(DataChunkSourceTest, BgzipSourceVirtualOffsets)
{
  auto const filename = temp_env->get_temp_filepath("bgzip_source");
  std::string input{"bananarama"};
  for (int i = 0; i < 24; i++) {
    input = input + input;
  }
  std::string padding_garbage{"garbage"};
  for (int i = 0; i < 10; i++) {
    padding_garbage = padding_garbage + padding_garbage;
  }
  std::string const data_garbage{"GARBAGE"};
  std::string const begininput{"begin of bananarama"};
  std::string const endinput{"end of bananarama"};
  std::size_t begin_compressed_offset{};
  std::size_t end_compressed_offset{};
  std::size_t const begin_local_offset{data_garbage.size()};
  std::size_t const end_local_offset{endinput.size()};
  {
    std::ofstream stream{filename};
    stream.write(padding_garbage.data(), padding_garbage.size());
    std::default_random_engine rng{};
    begin_compressed_offset = stream.tellp();
    cudf::io::text::detail::bgzip::write_uncompressed_block(stream, data_garbage + begininput);
    write_bgzip(stream, input, rng, false, false);
    end_compressed_offset = stream.tellp();
    cudf::io::text::detail::bgzip::write_uncompressed_block(stream,
                                                            endinput + data_garbage + data_garbage);
    cudf::io::text::detail::bgzip::write_uncompressed_block(stream, {});
    stream.write(padding_garbage.data(), padding_garbage.size());
  }
  input = begininput + input + endinput;

  auto const source =
    cudf::io::text::make_source_from_bgzip_file(filename,
                                                begin_compressed_offset << 16 | begin_local_offset,
                                                end_compressed_offset << 16 | end_local_offset);

  test_source(input, *source);
}

TEST_F(DataChunkSourceTest, BgzipSourceVirtualOffsetsSingleGZipBlock)
{
  auto const filename = temp_env->get_temp_filepath("bgzip_source");
  std::string const input{"collection unit brings"};
  std::string const head_garbage{"garbage"};
  std::string const tail_garbage{"GARBAGE"};
  std::size_t begin_compressed_offset{};
  std::size_t end_compressed_offset{};
  std::size_t const begin_local_offset{head_garbage.size()};
  std::size_t const end_local_offset{head_garbage.size() + input.size()};
  {
    std::ofstream stream{filename};
    cudf::io::text::detail::bgzip::write_uncompressed_block(stream,
                                                            head_garbage + input + tail_garbage);
    cudf::io::text::detail::bgzip::write_uncompressed_block(stream, {});
  }

  auto const source =
    cudf::io::text::make_source_from_bgzip_file(filename,
                                                begin_compressed_offset << 16 | begin_local_offset,
                                                end_compressed_offset << 16 | end_local_offset);

  test_source(input, *source);
}

TEST_F(DataChunkSourceTest, BgzipSourceVirtualOffsetsSingleChunk)
{
  auto const filename = temp_env->get_temp_filepath("bgzip_source");
  std::string const input{"collection unit brings"};
  std::string const head_garbage{"garbage"};
  std::string const tail_garbage{"GARBAGE"};
  std::size_t begin_compressed_offset{};
  std::size_t end_compressed_offset{};
  std::size_t const begin_local_offset{head_garbage.size()};
  std::size_t const end_local_offset{input.size() - 10};
  {
    std::ofstream stream{filename};
    cudf::io::text::detail::bgzip::write_uncompressed_block(stream,
                                                            head_garbage + input.substr(0, 10));
    end_compressed_offset = stream.tellp();
    cudf::io::text::detail::bgzip::write_uncompressed_block(stream,
                                                            input.substr(10) + tail_garbage);
    cudf::io::text::detail::bgzip::write_uncompressed_block(stream, {});
  }

  auto const source =
    cudf::io::text::make_source_from_bgzip_file(filename,
                                                begin_compressed_offset << 16 | begin_local_offset,
                                                end_compressed_offset << 16 | end_local_offset);

  test_source(input, *source);
}

TEST_F(DataChunkSourceTest, BgzipCompressedSourceVirtualOffsets)
{
  auto const filename = temp_env->get_temp_filepath("bgzip_source_compressed_offsets");
  std::string input{"bananarama"};
  for (int i = 0; i < 24; i++) {
    input = input + input;
  }
  std::string padding_garbage{"garbage"};
  for (int i = 0; i < 10; i++) {
    padding_garbage = padding_garbage + padding_garbage;
  }
  std::string const data_garbage{"GARBAGE"};
  std::string const begininput{"begin of bananarama"};
  std::string const endinput{"end of bananarama"};
  std::size_t begin_compressed_offset{};
  std::size_t end_compressed_offset{};
  std::size_t const begin_local_offset{data_garbage.size()};
  std::size_t const end_local_offset{endinput.size()};
  {
    std::ofstream stream{filename};
    stream.write(padding_garbage.data(), padding_garbage.size());
    std::default_random_engine rng{};
    begin_compressed_offset = stream.tellp();
    cudf::io::text::detail::bgzip::write_compressed_block(stream, data_garbage + begininput);
    write_bgzip(stream, input, rng, true, false);
    end_compressed_offset = stream.tellp();
    cudf::io::text::detail::bgzip::write_compressed_block(stream,
                                                          endinput + data_garbage + data_garbage);
    cudf::io::text::detail::bgzip::write_uncompressed_block(stream, {});
    stream.write(padding_garbage.data(), padding_garbage.size());
  }
  input = begininput + input + endinput;

  auto source =
    cudf::io::text::make_source_from_bgzip_file(filename,
                                                begin_compressed_offset << 16 | begin_local_offset,
                                                end_compressed_offset << 16 | end_local_offset);
  test_source(input, *source);
}

CUDF_TEST_PROGRAM_MAIN()
