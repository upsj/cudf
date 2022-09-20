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

#pragma once

#include <cudf/utilities/error.hpp>
#include <cudf/utilities/span.hpp>

#include <algorithm>
#include <array>
#include <fstream>
#include <limits>

#include <zlib.h>

namespace cudf::io::text::detail::bgzip {

template <typename IntType>
static IntType read_int(char* data)
{
  IntType result{};
  // we assume little-endian
  std::memcpy(&result, &data[0], sizeof(result));
  return result;
}

template <typename T>
void write_int(std::ostream& stream, T val)
{
  std::array<char, sizeof(T)> bytes;
  // we assume little-endian
  std::memcpy(&bytes[0], &val, sizeof(T));
  stream.write(bytes.data(), bytes.size());
}

struct header {
  int block_size;
  int extra_length;
  [[nodiscard]] int data_size() const { return block_size - extra_length - 20; }
};

header read_header(std::istream& stream)
{
  std::array<char, 12> buffer{};
  stream.read(buffer.data(), sizeof(buffer));
  std::array<uint8_t, 4> const expected_header{{31, 139, 8, 4}};
  CUDF_EXPECTS(
    std::equal(
      expected_header.begin(), expected_header.end(), reinterpret_cast<uint8_t*>(buffer.data())),
    "malformed BGZIP header");
  // we ignore the remaining bytes of the fixed header, since they don't matter to us
  auto const extra_length = read_int<uint16_t>(&buffer[10]);
  uint16_t extra_offset{};
  // read all the extra subfields
  while (extra_offset < extra_length) {
    auto const remaining_size = extra_length - extra_offset;
    CUDF_EXPECTS(remaining_size >= 4, "invalid extra field length");
    // a subfield consists of 2 identifier bytes and a uint16 length
    // 66/67 identifies a BGZIP block size field, we skip all other fields
    stream.read(buffer.data(), 4);
    extra_offset += 4;
    auto const subfield_size = read_int<uint16_t>(&buffer[2]);
    if (buffer[0] == 66 && buffer[1] == 67) {
      // the block size subfield contains a single uint16 value, which is block_size - 1
      CUDF_EXPECTS(subfield_size == sizeof(uint16_t), "malformed BGZIP extra subfield");
      stream.read(buffer.data(), sizeof(uint16_t));
      stream.seekg(remaining_size - 6, std::ios_base::cur);
      auto const block_size_minus_one = read_int<uint16_t>(&buffer[0]);
      return {block_size_minus_one + 1, extra_length};
    } else {
      stream.seekg(subfield_size, std::ios_base::cur);
      extra_offset += subfield_size;
    }
  }
  CUDF_FAIL("missing BGZIP size extra subfield");
}

struct footer {
  uint32_t crc;
  uint32_t decompressed_size;
};

footer read_footer(std::istream& stream)
{
  std::array<char, 8> buffer{};
  stream.read(buffer.data(), sizeof(buffer));
  return {read_int<uint32_t>(&buffer[0]), read_int<uint32_t>(&buffer[4])};
}

void write_footer(std::ostream& stream, host_span<char const> data)
{
  // compute crc32 with zlib, this allows checking the generated files with external tools
  write_int<uint32_t>(stream, crc32(0, (unsigned char*)data.data(), data.size()));
  write_int<uint32_t>(stream, data.size());
}

void write_header(std::ostream& stream,
                  uint16_t compressed_size,
                  host_span<char const> pre_size_subfield,
                  host_span<char const> post_size_subfield)
{
  auto uint8_to_char = [](uint8_t val) {
    char c{};
    std::memcpy(&c, &val, 1);
    return c;
  };
  std::array<char, 10> const header_data{{
    31,                  // magic number
    uint8_to_char(139),  // magic number
    8,                   // compression type: deflate
    4,                   // flags: extra header
    0,                   // mtime
    0,                   // mtime
    0,                   // mtime
    0,                   // mtime: irrelevant
    4,                   // xfl: irrelevant
    3                    // OS: irrelevant
  }};
  stream.write(header_data.data(), header_data.size());
  std::array<char, 4> extra_blocklen_field{{66, 67, 2, 0}};
  auto const extra_size = pre_size_subfield.size() + extra_blocklen_field.size() +
                          sizeof(uint16_t) + post_size_subfield.size();
  auto const block_size =
    header_data.size() + sizeof(uint16_t) + extra_size + compressed_size + 2 * sizeof(uint32_t);
  write_int<uint16_t>(stream, extra_size);
  stream.write(pre_size_subfield.data(), pre_size_subfield.size());
  stream.write(extra_blocklen_field.data(), extra_blocklen_field.size());
  CUDF_EXPECTS(block_size - 1 <= std::numeric_limits<uint16_t>::max(), "block size overflow");
  write_int<uint16_t>(stream, block_size - 1);
  stream.write(post_size_subfield.data(), post_size_subfield.size());
}

void write_uncompressed_block(std::ostream& stream,
                              host_span<char const> data,
                              host_span<char const> extra_garbage_before = {},
                              host_span<char const> extra_garbage_after  = {})
{
  CUDF_EXPECTS(data.size() <= std::numeric_limits<uint16_t>::max(), "data size overflow");
  write_header(stream, data.size() + 5, extra_garbage_before, extra_garbage_after);
  write_int<uint8_t>(stream, 1);
  write_int<uint16_t>(stream, data.size());
  write_int<uint16_t>(stream, ~static_cast<uint16_t>(data.size()));
  stream.write(data.data(), data.size());
  write_footer(stream, data);
}

void write_compressed_block(std::ostream& stream,
                            host_span<char const> data,
                            host_span<char const> extra_garbage_before = {},
                            host_span<char const> extra_garbage_after  = {})
{
  CUDF_EXPECTS(data.size() <= std::numeric_limits<uint16_t>::max(), "data size overflow");
  z_stream deflate_stream{};
  // let's make sure we have enough space to store the data
  std::vector<char> compressed_out(data.size() * 2 + 256);
  deflate_stream.next_in   = (unsigned char*)data.data();
  deflate_stream.avail_in  = data.size();
  deflate_stream.next_out  = (unsigned char*)compressed_out.data();
  deflate_stream.avail_out = compressed_out.size();
  CUDF_EXPECTS(
    deflateInit2(&deflate_stream,        // stream
                 Z_DEFAULT_COMPRESSION,  // compression level
                 Z_DEFLATED,             // method
                 -15,  // log2 of window size (negative value means no ZLIB header/footer)
                 9,    // mem level: best performance/most memory usage for compression
                 Z_DEFAULT_STRATEGY  // strategy
                 ) == Z_OK,
    "deflateInit failed");
  CUDF_EXPECTS(deflate(&deflate_stream, Z_FINISH) == Z_STREAM_END, "deflate failed");
  CUDF_EXPECTS(deflateEnd(&deflate_stream) == Z_OK, "deflateEnd failed");
  write_header(stream, deflate_stream.total_out, extra_garbage_before, extra_garbage_after);
  stream.write(compressed_out.data(), deflate_stream.total_out);
  write_footer(stream, data);
}

}  // namespace cudf::io::text::detail::bgzip
