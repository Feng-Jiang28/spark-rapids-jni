#pragma once

#include <cudf/table/table_view.hpp>
#include <cudf/column/column.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/scalar/scalar.hpp>
#include <cudf/types.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/dictionary/dictionary_column_view.hpp>
#include <cudf/table/table.hpp>
#include <cudf/filling.hpp>

#include <rmm/device_buffer.hpp>
#include <rmm/device_vector.hpp>
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include "utils.cuh"

#include "phj_util.cuh"
#include "partition_util.cuh"

#include <cudf/column/column_view.hpp>

#include <iostream>

#include <cuda.h>
#include <cub/cub.cuh>

#include <thrust/gather.h>

class SortHashGather {

public:
    // views of two tables to be joined
    // int first_bit: Likely used in the hash function.
    // int radix_bits: Used to determine the number of partitions.
    // int circular_buffer_size: Size of a circular buffer used in the join operation.
    explicit SortHashGather(cudf::table_view source_table, cudf::column_view gather_map, int n_match, int circular_buffer_size, int first_bit,  int radix_bits)
    : source_table(source_table)
    , gather_map(gather_map)
    , n_match(n_match)
    , circular_buffer(circular_buffer_size)
    , first_bit(first_bit)
    , radix_bits(radix_bits)
    {

        allocate_mem(&keys_partitions, false, sizeof(key_t)*(circular_buffer+2048));  // 1 Mc used, memory used now.
        allocate_mem(&vals_partitions, false, sizeof(int32_t)*(circular_buffer+2048)); // 3 Mc used, memory used now.
        cudaEventCreate(&start);
        cudaEventCreate(&stop);
    }

    std::unique_ptr<cudf::table> materialize_by_gather() {
        key_t* keys  {nullptr};

        in_copy(&keys, source_table, 0);

        // Assuming gather_map1 is your cudf::column_view
        int* match_idx; // Device pointer

        // Allocate memory for s_match_idx on the device
        cudaMalloc(&match_idx, gather_map.size() * sizeof(int));

        // Copy data from the column_view to the device pointer
        cudaMemcpy(match_idx, gather_map.data<int>(), gather_map.size() * sizeof(int), cudaMemcpyDeviceToDevice);

        // Create a cudf::table from the column
        std::vector<std::unique_ptr<cudf::column>> columns;

        for (int i = 1; i < cols; ++i) {

            key_t* col {nullptr};
            cudaMalloc(&col, circular_buffer * sizeof(key_t));
            key_t* vals {nullptr};

            in_copy(&vals, source_table, i);
            if(i > 0) partition_pairs(keys, vals, (key_t*)keys_partitions, (key_t*)vals_partitions, nullptr, circular_buffer); // Mt + 2Mc is allocated.
            thrust::device_ptr<key_t> dev_data_ptr((key_t*)vals_partitions);
            thrust::device_ptr<int> dev_idx_ptr(match_idx);

            thrust::device_ptr<key_t> dev_out_ptr(col);
            thrust::gather(dev_idx_ptr, dev_idx_ptr+std::min(circular_buffer, n_match), dev_data_ptr, dev_out_ptr);
            // First, create a column_view
            cudf::column_view col_view(
                cudf::data_type{cudf::type_to_id<key_t>()},
                static_cast<cudf::size_type>(std::min(circular_buffer, n_match)),
                col,  // assuming 'col' is a device pointer to your data
                nullptr,  // null mask (nullptr if no null values)
                0  // null count (0 if no null values)
            );

            //print_column_view(col_view);

            // Then, create a cudf::column from the column_view
            auto col_column = std::make_unique<cudf::column>(col_view);

            columns.push_back(std::move(col_column));
        }

        return std::make_unique<cudf::table>(std::move(columns));
    }

    void print_column_view(cudf::column_view const& col) {
        // Check the type of the column
        if (col.type().id() == cudf::type_id::INT32) {
            // Create a device vector from the column data
            thrust::device_vector<int> d_data(col.begin<int>(), col.end<int>());

            // Copy to host
            thrust::host_vector<int> h_data = d_data;

            // Print the data
            for (auto const& val : h_data) {
                std::cout << val << " ";
            }
            std::cout << std::endl;
        }
        else {
            // Handle other types as needed
            std::cout << "Unsupported type" << std::endl;
        }
    }

    ~SortHashGather() {

        release_mem(keys_partitions);
        release_mem(vals_partitions);

        cudaEventDestroy(start);
        cudaEventDestroy(stop);
    }

public:
    float mat_time {0};
    float copy_device_vector_time{0};

private:

    void in_copy(key_t** arr, cudf::table_view table, int index){

        // Get the column_view for the first column (index 0) because we only support single key join now.
        cudf::column_view first_column = table.column(index);
        //std::cout << first_column.size() << std::endl;
        // Get the type of the first column.
        cudf::data_type dtype_r = first_column.type();
        const void* data_ptr_r;
        if (dtype_r.id() == cudf::type_id::INT32) {
            // The column type is INT32
            data_ptr_r = static_cast<const void*>(first_column.data<int32_t>());
            // Proceed with your INT32-specific logic here
        } else {
            // Handle other data types or throw an error if INT32 is required
             throw std::runtime_error("R key type not supported");
        }

        *arr = const_cast<key_t*>(reinterpret_cast<const key_t*>(data_ptr_r));
    }


    template<typename KeyT, typename ValueT>
    void partition_pairs(KeyT*    keys,
                        ValueT*   values,
                        KeyT*     keys_out,
                        ValueT*   values_out,
                        int*      offsets,
                        const int num_items) {
        // offsets array to store offsets for each partition
        // num_items: number of key-value pairs to partition

        SinglePassPartition<KeyT, ValueT, int> ssp(keys, values, keys_out, values_out, offsets, num_items, first_bit, radix_bits);
        ssp.process();
    }

private:

    const cudf::table_view source_table;

    const cudf::column_view gather_map;

    const int circular_buffer;

    using key_t = int32_t;

    int cols = source_table.num_columns();

    int n_match;

    void*  keys_partitions{nullptr};
    void*  vals_partitions{nullptr};

    int first_bit;
    int radix_bits;

    cudaEvent_t start;
    cudaEvent_t stop;
};
