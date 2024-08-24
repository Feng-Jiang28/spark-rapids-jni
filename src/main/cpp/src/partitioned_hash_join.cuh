#pragma once

#include <cudf/table/table_view.hpp>
#include <cudf/column/column.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/scalar/scalar.hpp>
#include <cudf/types.hpp>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/dictionary/dictionary_column_view.hpp>
#include <rmm/device_buffer.hpp>
#include <rmm/device_vector.hpp>
#include <thrust/device_vector.h>
#include "utils.cuh"

#include <cudf/column/column_view.hpp>

#include <iostream>

#include <cuda.h>
#include <cub/cub.cuh>

class PartitionHashJoin {

public:
    explicit PartitionHashJoin(cudf::table_view r_in, cudf::table_view s_in, int log_parts1, int log_parts2, int first_bit, int circular_buffer_size)
    : r(r_in)
    , s(s_in)
    , log_parts1(log_parts1)
    , log_parts2(log_parts2)
    , first_bit(first_bit)
    , circular_buffer_size(circular_buffer_size)
    {
        nr = static_cast<int>(r.num_rows());
        ns = static_cast<int>(s.num_rows());

        parts1 = 1 << log_parts1;
        parts2 = 1 << (log_parts1 + log_parts2);

        buckets_num_max_R    = ((((nr + parts2 - 1)/parts2) + bucket_size - 1)/bucket_size)*parts2 + 1024;
        // we consider two extreme cases here
        // (1) S keys are uniformly distributed across partitions; (2) S keys concentrate in one partition
        buckets_num_max_S    = std::max(((((ns + parts2 - 1)/parts2) + bucket_size - 1)/bucket_size)*parts2,
                                        (ns+bucket_size-1)/bucket_size+parts2);

        allocate_mem(&r_key_partitions, true, buckets_num_max_R * bucket_size * sizeof(key_t));
        allocate_mem(&s_key_partitions, true, buckets_num_max_S * bucket_size * sizeof(key_t));

        // Get the column_view for the first column (index 0)
        cudf::column_view first_column = r_in.column(0);

        cudf::data_type dtype = first_column.type();
        cudf::type_id type_id = dtype.id();
        void* data_ptr = nullptr;
        data_ptr = const_cast<void*>(static_cast<const void*>(first_column.data<int32_t>()));

        // Perform cudaMemcpy and check for errors
        cudaError_t cudaStatus = cudaMemcpy(r_key_partitions, data_ptr, nr*sizeof(int32_t), cudaMemcpyDefault);

        if (cudaStatus != cudaSuccess) {
            fprintf(stderr, "cudaMemcpy failed: %s\n", cudaGetErrorString(cudaStatus));
            // Handle the error appropriately, e.g., throw an exception or return an error code
            throw std::runtime_error("cudaMemcpy failed");
        }else{
            std::cout << "memory allocated cudaSuccess!" << std::endl;
        }

        //cudaMemcpy(s_key_partitions, COL(s,0), ns*sizeof(key_t), cudaMemcpyDefault);
//  #ifndef CHECK_CORRECTNESS
//          release_mem(COL(r,0));
//          release_mem(COL(s,0));
//  #endif

        allocate_mem(&r_key_partitions_temp, true, buckets_num_max_R * bucket_size * sizeof(key_t));
        allocate_mem(&s_key_partitions_temp, true, buckets_num_max_S * bucket_size * sizeof(key_t));


        // late materialization
        allocate_mem(&r_val_partitions, true, buckets_num_max_R * bucket_size * sizeof(int32_t));
        allocate_mem(&r_val_partitions_temp, true, buckets_num_max_R * bucket_size * sizeof(int32_t));
        allocate_mem(&s_val_partitions, true, buckets_num_max_S * bucket_size * sizeof(int32_t));
        allocate_mem(&s_val_partitions_temp, true, buckets_num_max_S * bucket_size * sizeof(int32_t));
        allocate_mem(&r_match_idx, false, sizeof(int)*circular_buffer_size);
        allocate_mem(&s_match_idx, false, sizeof(int)*circular_buffer_size);
        fill_sequence<<<num_tb(nr), 1024>>>((int*)(r_val_partitions), 0, nr);
        fill_sequence<<<num_tb(ns), 1024>>>((int*)(s_val_partitions), 0, ns);

        for (int i = 0; i < 2; i++) {
            allocate_mem(&chains_R[i], false, buckets_num_max_R * sizeof(uint32_t));
            allocate_mem(&cnts_R[i], false, parts2 * sizeof(uint32_t));
            allocate_mem(&heads_R[i], false, parts2 * sizeof(uint64_t));
            allocate_mem(&buckets_used_R[i], false, sizeof(uint32_t));

            allocate_mem(&chains_S[i], false, buckets_num_max_S * sizeof(uint32_t));
            allocate_mem(&cnts_S[i], false, parts2 * sizeof(uint32_t));
            allocate_mem(&heads_S[i], false, parts2 * sizeof(uint64_t));
            allocate_mem(&buckets_used_S[i], false, sizeof(uint32_t));
        }

        bucket_info_R = (uint32_t*)s_val_partitions_temp;

        allocate_mem(&d_n_matches);

   }

    void test_column_factories() {
        std::cout << "Hello I am here: " << std::endl;
        auto empty_col = cudf::make_empty_column(cudf::data_type{cudf::type_id::INT32});
        std::cout << "Empty column size: " << empty_col->size() << std::endl;

        auto numeric_col = cudf::make_numeric_column(cudf::data_type{cudf::type_id::FLOAT64}, 1000);
        std::cout << "Numeric column size: " << numeric_col->size() << std::endl;
    }

    void join(){
         partition();
         hash_join();
    }

    ~PartitionHashJoin() {}
public:
    float partition_time {0};
    float join_time {0};
    float mat_time {0};

private:

    template<typename KeyT, typename val_t>
    void partition(KeyT* keys, KeyT* keys_out,
                       val_t* vals, val_t* vals_out, int n, int buckets_num,
                       uint64_t* heads[2], uint32_t* cnts[2],
                       uint32_t* chains[2], uint32_t* buckets_used[2]) {
        constexpr int NT = (sizeof(KeyT) == 4 ? 1024 : 512);
        constexpr int VT = 4;

        // shuffle region + histogram region + extra meta info
        const size_t p1_sm_bytes = (NT*VT) * max(sizeof(KeyT), sizeof(val_t)) + (4*(1 << log_parts1)) * sizeof(int32_t);
        const size_t p2_sm_bytes = (NT*VT) * max(sizeof(KeyT), sizeof(val_t)) + (4*(1 << log_parts2)) * sizeof(int32_t);

        const int sm_counts = 70; // need to change later.

      // Initialize Metadata:
        // init_metadata_double: A CUDA kernel that initializes metadata for buckets, such as heads, chains, and counts.
        init_metadata_double<<<sm_counts, NT, 0>>> (
            heads[0], buckets_used[0], chains[0], cnts[0],
            1 << log_parts1, buckets_num,
            heads[1], buckets_used[1], chains[1], cnts[1],
            1 << (log_parts1 + log_parts2), buckets_num,
            bucket_size
        );

        // partition_pass_one: A CUDA kernel that performs the first pass of partitioning. It distributes keys and
        // values into initial buckets based on log_parts1.
        partition_pass_one<NT, VT><<<sm_counts, NT, p1_sm_bytes>>>(
                                                    keys,
                                                    vals,
                                                    heads[0],
                                                    buckets_used[0],
                                                    chains[0],
                                                    cnts[0],
                                                    keys_out,
                                                    vals_out,
                                                    n,
                                                    log_parts1,
                                                    first_bit + log_parts2,
                                                    log2_bucket_size);
        // Compute Bucket Information:
        // compute_bucket_info: A CUDA kernel that processes chain information to prepare for the second pass.
        compute_bucket_info <<<sm_counts, NT>>> (chains[0], cnts[0], log_parts1);

        // Second Partition Pass:
        // partition_pass_two: A CUDA kernel that refines the partitioning, redistributing keys and values into final buckets based on log_parts2.
        partition_pass_two<NT, VT> <<<sm_counts, NT, p2_sm_bytes>>>(
                                        keys_out,
                                        vals_out,
                                        chains[0],
                                        buckets_used[1],
                                        heads[1],
                                        chains[1],
                                        cnts[1],
                                        keys,
                                        vals,
                                        log_parts2,
                                        first_bit,
                                        buckets_used[0],
                                        log2_bucket_size);
    }


    void partition() {

        partition(r_key_partitions, r_key_partitions_temp,
                  (int*)(r_val_partitions), (int*)(r_val_partitions_temp),
                  nr,
                  buckets_num_max_R, heads_R, cnts_R, chains_R, buckets_used_R);

        partition(s_key_partitions, s_key_partitions_temp,
                  (int*)(s_val_partitions), (int*)(s_val_partitions_temp),
                  ns,
                  buckets_num_max_S, heads_S, cnts_S, chains_S, buckets_used_S);

    }

    void balance_buckets() {
        decompose_chains <<<(1 << log_parts1), 1024>>> (bucket_info_R, chains_R[1], cnts_R[1], log_parts1 + log_parts2, 2*bucket_size, bucket_size);
    }

    void hash_join() {
        constexpr int NT = 512;
        constexpr int VT = 4;


    }

    void swap_r_s() {
        // Swap the key partitions of R and S.
        // Swap the value partitions of R and S.
        //  Swap the match indices used in the join process.
        std::swap(r_key_partitions, s_key_partitions);
        std::swap(r_val_partitions, s_val_partitions);
        std::swap(r_match_idx, s_match_idx);
        /*
        Iterates over index i for two elements:
        chains_R[i] and chains_S[i]: Swap the chain metadata for R and S.
        cnts_R[i] and cnts_S[i]: Swap the count metadata.
        heads_R[i] and heads_S[i]: Swap the head pointers for bucket lists.
        buckets_used_R[i] and buckets_used_S[i]: Swap the used bucket metadata.
        */
        for (int i = 0; i < 2; i++) {
            std::swap(chains_R[i], chains_S[i]);
            std::swap(cnts_R[i], cnts_S[i]);
            std::swap(heads_R[i], heads_S[i]);
            std::swap(buckets_used_R[i], buckets_used_S[i]);
        }
        /*
        This function effectively reverses the roles of R and S, which can be beneficial for
        ensuring that both datasets are evenly processed. It swaps all relevant data and metadata
        structures to achieve this.
        */
    }



    // no need to do this because it is done in cudf.
    void materialize_by_gather(){

    }

    void partition_pairs() {}


    static constexpr uint32_t log2_bucket_size = 12;
    static constexpr uint32_t bucket_size = (1 << log2_bucket_size);

    const cudf::table_view r;
    const cudf::table_view s;

    int nr;
    int ns;
    int n_matches;
    int circular_buffer_size;

    int first_bit;
    int parts1;
    int parts2;
    int log_parts1;
    int log_parts2;
    size_t buckets_num_max_R;
    size_t buckets_num_max_S;

    key_t* r_key_partitions      {nullptr};
    key_t* s_key_partitions      {nullptr};
    key_t* r_key_partitions_temp {nullptr};
    key_t* s_key_partitions_temp {nullptr};

    void* r_val_partitions       {nullptr};
    void* s_val_partitions       {nullptr};
    void* r_val_partitions_temp  {nullptr};
    void* s_val_partitions_temp  {nullptr};

    // meta info for bucket chaining
    uint32_t* chains_R[2];
    uint32_t* chains_S[2];

    uint32_t* cnts_R[2];
    uint32_t* cnts_S[2];

    uint64_t* heads_R[2];
    uint64_t* heads_S[2];

    uint32_t* buckets_used_R[2];
    uint32_t* buckets_used_S[2];

    uint32_t* bucket_info_R{nullptr};

    int*   r_match_idx     {nullptr};
    int*   s_match_idx     {nullptr};

    int*   d_n_matches     {nullptr};
};