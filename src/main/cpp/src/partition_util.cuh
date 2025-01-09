#pragma once

#include <iostream>
#include <stdio.h>
#include <string>
#include <type_traits>
#include "utils.cuh"

#include <cuda.h>
#include <cub/cub.cuh>

#include <rmm/resource_ref.hpp>
#include <rmm/cuda_stream_view.hpp>

__global__ void generate_work_units(const int* __restrict__  r_offsets, 
                                    const int* __restrict__  s_offsets, 
                                    uint64_t*  __restrict__  r_work, 
                                    uint64_t*  __restrict__  s_work, 
                                    int*                     total_work, // make sure this is initialized to 0
                                    const int                n_partitions, 
                                    const int                threshold) {
    for(int p = get_cuda_tid(); p < n_partitions; p += nthreads()) {
        uint64_t r_start = (p >= 1 ? r_offsets[p-1] : 0);
        uint64_t r_end = r_offsets[p];
        uint64_t s_start = (p >= 1 ? s_offsets[p-1] : 0);
        uint64_t s_end = s_offsets[p];
        auto r_len = r_end - r_start;
        auto s_len = s_end - s_start;
        
        auto n_units = (s_len + threshold - 1)/threshold;
        auto pos = atomicAdd(total_work, n_units);

        #pragma unroll
        for(int i = 0; i < n_units; i++, pos++, s_len -= threshold, s_start += threshold) {
            r_work[pos] = (r_start << 32) + r_len;
            s_work[pos] = (s_start << 32) + min(s_len, (uint64_t)threshold);
        }
    }
}

__global__ void generate_work_units_coarse_offsets(const int* r_fined_offsets,
                                      const int* s_fined_offsets,
                                      uint64_t*  __restrict__  r_work,
                                      uint64_t*  __restrict__  s_work,
                                      const int coarse_radix_bits,
                                      const int fined_radix_bits,
                                      const int* flag,
                                      int* total_work,
                                      const int threshold
                                      ){
    int fined_partition = 1 << fined_radix_bits;
    int fined_partition_coarse_partition = 1 << (fined_radix_bits - coarse_radix_bits);
    for(int p = get_cuda_tid(); p < fined_partition && flag[p/fined_partition_coarse_partition] == 1; p += nthreads()) {
        uint64_t r_start = (p >= 1 ? r_fined_offsets[p-1] : 0);
        uint64_t r_end = r_fined_offsets[p];
        uint64_t s_start = (p >= 1 ? s_fined_offsets[p-1] : 0);
        uint64_t s_end = s_fined_offsets[p];
        auto r_len = r_end - r_start;
        auto s_len = s_end - s_start;

        auto n_units = (s_len + threshold - 1)/threshold;
        auto pos = atomicAdd(total_work, n_units);

        #pragma unroll
        for(int i = 0; i < n_units; i++, pos++, s_len -= threshold, s_start += threshold) {
            r_work[pos] = (r_start << 32) + r_len;
            s_work[pos] = (s_start << 32) + min(s_len, (uint64_t)threshold);
        }
    }
}

__global__ void generate_work_units_coarse_offsets(const int* r_coarse_offsets,
                                      const int* s_coarse_offsets,
                                      uint64_t*  __restrict__  r_work,
                                      uint64_t*  __restrict__  s_work,
                                      const int coarse_radix_bits,
                                      const int fined_radix_bits,
                                      const int* flag,
                                      int* total_work
                                      ){
    int coarse_partition = 1 << coarse_radix_bits;
    for(int p = get_cuda_tid(); p < coarse_partition && flag[p] == 0; p += nthreads()) {
        uint64_t r_start = (p >= 1 ? r_coarse_offsets[p-1] : 0);
        uint64_t r_end = r_coarse_offsets[p];
        uint64_t s_start = (p >= 1 ? s_coarse_offsets[p-1] : 0);
        uint64_t s_end = s_coarse_offsets[p];
        auto r_len = r_end - r_start;
        auto s_len = s_end - s_start;

        auto pos = atomicAdd(total_work, 1);

        r_work[pos] = (r_start << 32) + r_len;
        s_work[pos] = (s_start << 32) + s_len;
    }
}

template<typename key_t, typename value_t, typename off_t>
class SinglePassPartition {
public:
    SinglePassPartition() = delete;
    SinglePassPartition(key_t* keys, 
                        value_t* values, 
                        key_t* keys_out,
                        value_t* values_out,
                        off_t* offsets,
                        const long N, 
                        const int first_bit,
                        const int radix_bits,
                        rmm::cuda_stream_view stream,
                        rmm::device_async_resource_ref mr)
    : keys(keys)
    , values(values)
    , keys_out(keys_out)
    , values_out(values_out)
    , offsets(offsets)
    , N(N)
    , begin_bit(first_bit)
    , end_bit(begin_bit+radix_bits)
    , radix_bits(radix_bits)
    , n_partitions(1 << radix_bits)
    , stream(stream)
    , mr(mr)
    {
        assert(end_bit <= sizeof(key_t)*8);

        allocate_mem(&d_counts_out, false, sizeof(int)*(n_partitions), stream, mr);
        if(values == nullptr){
            cub::DeviceRadixSort::SortKeys(d_temp_storage, temp_storage_bytes, keys, keys_out, N, begin_bit, end_bit);
        }
        else {
            cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes, keys, keys_out, values, values_out, N, begin_bit, end_bit);
        }
        try{
            allocate_mem(&d_temp_storage, false, temp_storage_bytes, stream, mr);
        }catch (const std::bad_alloc& e) {
            std::cerr << "Memory allocation failed: 2: " << temp_storage_bytes << " " << sizeof(int)*(n_partitions) << std::endl;
            // Handle the error, e.g., by freeing up other resources
        } catch (const std::exception& e) {
            std::cerr << "An unexpected error occurred: 2" << e.what() << std::endl;
        }
    }

    ~SinglePassPartition() {
        release_mem(d_temp_storage, temp_storage_bytes, stream, mr);
        release_mem(d_counts_out, sizeof(int), stream, mr);
    }

    template<typename T>
    struct RadixExtractor
    {   
        int begin_bit;
        int mask;
        __host__ __device__ RadixExtractor(int begin_bit, int end_bit) : begin_bit(begin_bit), mask((1 << (end_bit - begin_bit)) - 1) {}
        __host__ __device__ __forceinline__
        T operator()(const T &a) const {
            return (a >> begin_bit) & mask;
        }
    };
    
    void process() {
       if(values == nullptr){
           cub::DeviceRadixSort::SortKeys(d_temp_storage, temp_storage_bytes, keys, keys_out, N, begin_bit, end_bit);
       }
       else {
           cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes, keys, keys_out, values, values_out, N, begin_bit, end_bit);
       }
       if(offsets) {
           RadixExtractor<key_t> conversion_op(begin_bit, end_bit);
           cub::TransformInputIterator<key_t, RadixExtractor<key_t>, key_t*> itr(keys_out, conversion_op);
           size_t temp = 0;
           cub::DeviceHistogram::HistogramEven(nullptr, temp, itr, d_counts_out, n_partitions+1, 0, n_partitions, N);
           if(temp > temp_storage_bytes) {
               release_mem(d_temp_storage, temp_storage_bytes, stream, mr);
               allocate_mem(&d_temp_storage, false, temp, stream, mr);
               temp_storage_bytes = temp;
           }
           cub::DeviceHistogram::HistogramEven(d_temp_storage, temp_storage_bytes, itr, d_counts_out, n_partitions+1, 0, n_partitions, N);
           // offsets = [23, 41, 66, 85, 100] in what n th partition we have how many data falling in?
           cub::DeviceScan::InclusiveSum(d_temp_storage, temp_storage_bytes, d_counts_out, offsets, n_partitions);
       }
    }

private:
    const int n_partitions;
    const key_t* keys; 
    const value_t* values; 
    key_t* keys_out;
    value_t* values_out;
    off_t* offsets;
    long N; 
    int begin_bit; 
    int end_bit;
    int radix_bits;
    void* d_temp_storage {nullptr};
    size_t temp_storage_bytes {0};
    rmm::cuda_stream_view stream;
    rmm::device_async_resource_ref mr;
    int*  d_counts_out {nullptr};
};

template<int NT = 512,
         int VT = 4,
         int LOCAL_BUCKETS_BITS = 11,
         int SHUFFLE_SIZE = 32,
         typename KeyT,
         typename ValT,
         typename ValIt = cub::CountingInputIterator<ValT>>
__global__ void join_copartitions_arr(const KeyT* R, 
                                      ValIt Pr, 
                                      const KeyT* S, 
                                      ValIt Ps, 
                                      const uint64_t*  R_offsets, // offsets of partitions in R (inclusive prefix sum)
                                      const uint64_t*  S_offsets, // offsets of partitions in S (inclusive prefix sum)
                                      const int*  n_work_units, // number of work units 
                                      const int   log_parts, // number of partitions in log2
                                      const int   max_bucket_size, // more like max. partition size
                                      unsigned long long int*        results,
                                      ValT*       r_output,
                                      ValT*       s_output,
                                      const int   circular_buffer_size) {
    // LOCAL_BUCKETS = 1 << 11
    constexpr int LOCAL_BUCKETS = (1 << LOCAL_BUCKETS_BITS);

    extern __shared__ int16_t temp[];

    // SHUFFLE_SIZE = 32
    struct shuffle_space {
        ValT val_S_elem[SHUFFLE_SIZE];
        ValT val_R_elem[SHUFFLE_SIZE];
        KeyT key_elem[SHUFFLE_SIZE];
    };

    KeyT* elem = (KeyT*)temp;
    ValT* payload = (ValT*)&elem[max_bucket_size+512];
    int16_t* next = (int16_t*)&payload[max_bucket_size+512];
    int32_t* head = (int32_t*)&next[max_bucket_size+512];
    struct shuffle_space * shuffle = (struct shuffle_space *)&head[LOCAL_BUCKETS];

    const int tid = threadIdx.x;
    const int block = blockIdx.x;
    const int width = blockDim.x;
    const int pwidth = gridDim.x;
    const int parts = (1 << log_parts);
    const int buckets_cnt = *n_work_units;

    const int lid = tid % 32;
    const int gid = tid / 32;
    const int gnum = blockDim.x/32;

    int ptr;

    const int threadmask = (lid < 31)? ~((1 << (lid+1)) - 1) : 0;

    int shuffle_ptr = 0;

    auto warp_shuffle = shuffle + gid;

    // one thread block per partition
    // Always let R be the build table, S be the probe table
    for(uint32_t bucket_r = block; bucket_r < buckets_cnt; bucket_r += pwidth) {
        auto start = (R_offsets[bucket_r] >> 32);
        auto len_R = R_offsets[bucket_r] & 0xFFFFFFFF;

        for (int i = tid; i < LOCAL_BUCKETS; i += blockDim.x)
            head[i] = -1;
        __syncthreads();

        for(int base_r = 0; base_r < len_R; base_r += VT*blockDim.x) {
            KeyT data_R[VT];
            ValT data_Pr[VT];
            
            #pragma unroll
            for(int i = 0; i < VT; i++) {
                data_R[i] = R[start + base_r + VT*threadIdx.x + i];
                data_Pr[i] = Pr[start + base_r + VT*threadIdx.x + i];
            }
            
            int l_cnt_R = len_R - base_r - VT * threadIdx.x;                  

            #pragma unroll
            for (int k = 0; k < VT; k++) {
                if (k < l_cnt_R) {
                    auto val = data_R[k];
                    elem[base_r + k*blockDim.x + tid] = val;
                    payload[base_r + k*blockDim.x + tid] = data_Pr[k];
                    int hval = (val >> log_parts) & (LOCAL_BUCKETS - 1);

                    int32_t last = atomicExch(&head[hval], base_r + k*blockDim.x + tid);
                    next[base_r + k*blockDim.x + tid] = last;
                }
            }
        }
        __syncthreads();

        // probe
        start = (S_offsets[bucket_r] >> 32);
        auto len_S = S_offsets[bucket_r] & 0xFFFFFFFF;
        for(int offset_s = 0; offset_s < len_S; offset_s += VT*blockDim.x) {
            KeyT data_S[VT];
            ValT data_Ps[VT];
            
            #pragma unroll
            for(int i = 0; i < VT; i++) {
                data_S[i] = S[start + offset_s + VT*threadIdx.x + i];
                data_Ps[i] = Ps[start + offset_s + VT*threadIdx.x + i];
            }
            
            int l_cnt_S = len_S - offset_s - VT * threadIdx.x;

            #pragma unroll
            for (int k = 0; k < VT; k++) {
                auto val = data_S[k];
                auto pval = data_Ps[k];
                int32_t hval =  (val >> log_parts) & (LOCAL_BUCKETS - 1);
                ValT pay;

                int32_t pos = (k < l_cnt_S)? head[hval] : -1;

                /*check at warp level whether someone is still following chain => this way we can shuffle without risk*/
                int pred = (pos >= 0);

                while (__any_sync(__activemask(), pred)) {
                    int wr_intention = 0;

                    /*we have a match, fetch the data to be written*/
                    if (pred) {
                        if(elem[pos] == val) {
                            pay = payload[pos];
                            wr_intention = 1;
                        }

                        pos = next[pos];
                        pred = (pos >= 0);
                    }

                    /*find out who had a match in this execution step*/
                    int mask = __ballot_sync(__activemask(), wr_intention);

                    /*our software managed buffer will overflow, flush it*/
                    int wr_offset = shuffle_ptr +  __popc(mask & threadmask);
                    shuffle_ptr = shuffle_ptr + __popc(mask);
                    
                    /*while it overflows, flush
                    we flush 16 keys and then the 16 corresponding payloads consecutively, of course other formats might be friendlier*/
                    while (shuffle_ptr >= SHUFFLE_SIZE) {
                        if (wr_intention && (wr_offset < SHUFFLE_SIZE)) {
                            warp_shuffle->val_R_elem[wr_offset] = pay;
                            warp_shuffle->val_S_elem[wr_offset] = pval;
                            warp_shuffle->key_elem[wr_offset] = val;
                            wr_intention = 0;
                        }

                        if (lid == 0) {
                            ptr = atomicAdd(results,  (unsigned long long int)SHUFFLE_SIZE);
                        }

                        ptr = __shfl_sync(__activemask(), ptr, 0);

                        auto w_pos = (ptr + lid) % circular_buffer_size;

                        if(lid < SHUFFLE_SIZE) {
                            r_output[w_pos] = warp_shuffle->val_R_elem[lid];
                            s_output[w_pos] = warp_shuffle->val_S_elem[lid];
                            //keys_out[w_pos] = warp_shuffle->key_elem[lid];
                        }

                        wr_offset -= SHUFFLE_SIZE;
                        shuffle_ptr -= SHUFFLE_SIZE;
                    }

                    /*now the fit, write them in buffer*/
                    if (wr_intention && (wr_offset >= 0)) {
                        warp_shuffle->val_R_elem[wr_offset] = pay; // R
                        warp_shuffle->val_S_elem[wr_offset] = pval; // S
                        warp_shuffle->key_elem[wr_offset] = val; // key
                        wr_intention = 0;
                    }
                }                   
            }
        }

        if(bucket_r + pwidth >= buckets_cnt) break;
        __syncthreads();
    }

    if (lid == 0) {
        ptr = atomicAdd(results, (unsigned long long int)shuffle_ptr);
    }

    ptr = __shfl_sync(__activemask(), ptr, 0);

    if (lid < shuffle_ptr) {
        auto w_pos = (ptr + lid) % circular_buffer_size;
        if(lid < SHUFFLE_SIZE) {
            r_output[w_pos] = warp_shuffle->val_R_elem[lid];
            s_output[w_pos] = warp_shuffle->val_S_elem[lid];
            //keys_out[w_pos] = warp_shuffle->key_elem[lid];
        }
    }
}

__global__ void identify_large_partitions(const int* coarse_offset,
                          int n_partitions,
                          int bucket_size,
                          int* fine_partition_flag){
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= n_partitions) return;
    int start = idx == 0 ? 0 : coarse_offset[idx - 1];
    int end = coarse_offset[idx];
    int partition_size = coarse_offset[idx] - coarse_offset[idx - 1];
    fine_partition_flag[idx] = (partition_size > bucket_size) ? 1 : 0;
}

// flags:      [0, 1, 1, 0, 1]
// prefix_sum: [0, 0, 1, 1, 2]
void fine_partition_prefix_sum(const int* fine_partition_flag,
                                          int* fine_partition_prefix_sum,
                                          int n_coarse_partitions,
                                          rmm::cuda_stream_view stream,
                                          rmm::device_async_resource_ref mr){
    // Temporary storage for CUB
    void* d_temp_storage = nullptr;
    size_t temp_storage_bytes = 0;
    cub::DeviceScan::ExclusiveSum(d_temp_storage,
                                  temp_storage_bytes,
                                  fine_partition_flag,
                                  fine_partition_prefix_sum,
                                  n_coarse_partitions);
    allocate_mem(&d_temp_storage, false, temp_storage_bytes, stream, mr);
    cub::DeviceScan::ExclusiveSum(d_temp_storage,
                                  temp_storage_bytes,
                                  fine_partition_flag,
                                  fine_partition_prefix_sum,
                                  n_coarse_partitions);
    release_mem(d_temp_storage, temp_storage_bytes, stream, mr);

}



template<int NT = 512,
         int VT = 4,
         int LOCAL_BUCKETS_BITS = 11,
         int SHUFFLE_SIZE = 32,
         typename KeyT,
         typename ValT,
         typename ValI>
__global__ void join_copartitions_arr_v1(const KeyT* R,
                                      const ValI* Pr,
                                      const KeyT* S,
                                      const ValI* Ps,
                                      const uint64_t*  R_offsets, // offsets of partitions in R (inclusive prefix sum)
                                      const uint64_t*  S_offsets, // offsets of partitions in S (inclusive prefix sum)
                                      const int*  n_work_units, // number of work units
                                      const int   log_parts, // number of partitions in log2
                                      const int   max_bucket_size, // more like max. partition size
                                      unsigned long long int*        results,
                                      ValT*       r_output,
                                      ValT*       s_output,
                                      const long   circular_buffer_size) {
    constexpr int LOCAL_BUCKETS = (1 << LOCAL_BUCKETS_BITS);

    extern __shared__ int16_t temp[];

    struct shuffle_space {
        ValT val_S_elem[SHUFFLE_SIZE];
        ValT val_R_elem[SHUFFLE_SIZE];
        KeyT key_elem[SHUFFLE_SIZE];
    };

    KeyT* elem = (KeyT*)temp;
    ValT* payload = (ValT*)&elem[max_bucket_size+512];
    int16_t* next = (int16_t*)&payload[max_bucket_size+512];
    int32_t* head = (int32_t*)&next[max_bucket_size+512];
    struct shuffle_space * shuffle = (struct shuffle_space *)&head[LOCAL_BUCKETS];

    const int tid = threadIdx.x;
    const int block = blockIdx.x;
    const int width = blockDim.x;
    const int pwidth = gridDim.x;
    const int parts = (1 << log_parts);
    const int buckets_cnt = *n_work_units;

    const int lid = tid % 32;
    const int gid = tid / 32;
    const int gnum = blockDim.x/32;

    int ptr;

    const int threadmask = (lid < 31)? ~((1 << (lid+1)) - 1) : 0;

    int shuffle_ptr = 0;

    auto warp_shuffle = shuffle + gid;

    // one thread block per partition
    // Always let R be the build table, S be the probe table
    for(uint32_t bucket_r = block; bucket_r < buckets_cnt; bucket_r += pwidth) {
        auto start = (R_offsets[bucket_r] >> 32);
        auto len_R = R_offsets[bucket_r] & 0xFFFFFFFF;

        for (int i = tid; i < LOCAL_BUCKETS; i += blockDim.x)
            head[i] = -1;
        __syncthreads();

        for(int base_r = 0; base_r < len_R; base_r += VT*blockDim.x) {
            KeyT data_R[VT];
            ValT data_Pr[VT];

            #pragma unroll
            for(int i = 0; i < VT; i++) {
                data_R[i] = R[start + base_r + VT*threadIdx.x + i];
                data_Pr[i] = Pr[start + base_r + VT*threadIdx.x + i];
            }

            int l_cnt_R = len_R - base_r - VT * threadIdx.x;

            #pragma unroll
            for (int k = 0; k < VT; k++) {
                if (k < l_cnt_R) {
                    auto val = data_R[k];
                    elem[base_r + k*blockDim.x + tid] = val;
                    payload[base_r + k*blockDim.x + tid] = data_Pr[k];
                    int hval = (val >> log_parts) & (LOCAL_BUCKETS - 1);

                    int32_t last = atomicExch(&head[hval], base_r + k*blockDim.x + tid);
                    next[base_r + k*blockDim.x + tid] = last;
                }
            }
        }
        __syncthreads();

        // probe
        start = (S_offsets[bucket_r] >> 32);
        auto len_S = S_offsets[bucket_r] & 0xFFFFFFFF;
        for(int offset_s = 0; offset_s < len_S; offset_s += VT*blockDim.x) {
            KeyT data_S[VT];
            ValT data_Ps[VT];

            #pragma unroll
            for(int i = 0; i < VT; i++) {
                data_S[i] = S[start + offset_s + VT*threadIdx.x + i];
                data_Ps[i] = Ps[start + offset_s + VT*threadIdx.x + i];
            }

            int l_cnt_S = len_S - offset_s - VT * threadIdx.x;

            #pragma unroll
            for (int k = 0; k < VT; k++) {
                auto val = data_S[k];
                auto pval = data_Ps[k];
                int32_t hval =  (val >> log_parts) & (LOCAL_BUCKETS - 1);
                ValT pay;

                int32_t pos = (k < l_cnt_S)? head[hval] : -1;

                /*check at warp level whether someone is still following chain => this way we can shuffle without risk*/
                int pred = (pos >= 0);

                while (__any_sync(__activemask(), pred)) {
                    int wr_intention = 0;

                    /*we have a match, fetch the data to be written*/
                    if (pred) {
                        if(elem[pos] == val) {
                            pay = payload[pos];
                            wr_intention = 1;
                        }

                        pos = next[pos];
                        pred = (pos >= 0);
                    }

                    /*find out who had a match in this execution step*/
                    int mask = __ballot_sync(__activemask(), wr_intention);

                    /*our software managed buffer will overflow, flush it*/
                    int wr_offset = shuffle_ptr +  __popc(mask & threadmask);
                    shuffle_ptr = shuffle_ptr + __popc(mask);

                    /*while it overflows, flush
                    we flush 16 keys and then the 16 corresponding payloads consecutively, of course other formats might be friendlier*/
                    while (shuffle_ptr >= SHUFFLE_SIZE) {
                        if (wr_intention && (wr_offset < SHUFFLE_SIZE)) {
                            warp_shuffle->val_R_elem[wr_offset] = pay;
                            warp_shuffle->val_S_elem[wr_offset] = pval;
                            warp_shuffle->key_elem[wr_offset] = val;
                            wr_intention = 0;
                        }

                        if (lid == 0) {
                            ptr = atomicAdd(results,  (unsigned long long int)SHUFFLE_SIZE);
                        }

                        ptr = __shfl_sync(__activemask(), ptr, 0);

                        auto w_pos = (ptr + lid) % circular_buffer_size;

                        if(lid < SHUFFLE_SIZE) {
                            r_output[w_pos] = warp_shuffle->val_R_elem[lid];
                            s_output[w_pos] = warp_shuffle->val_S_elem[lid];
                            //keys_out[w_pos] = warp_shuffle->key_elem[lid];
                        }

                        wr_offset -= SHUFFLE_SIZE;
                        shuffle_ptr -= SHUFFLE_SIZE;
                    }

                    /*now the fit, write them in buffer*/
                    if (wr_intention && (wr_offset >= 0)) {
                        warp_shuffle->val_R_elem[wr_offset] = pay; // R
                        warp_shuffle->val_S_elem[wr_offset] = pval; // S
                        warp_shuffle->key_elem[wr_offset] = val; // key
                        wr_intention = 0;
                    }
                }
            }
        }

        if(bucket_r + pwidth >= buckets_cnt) break;
        __syncthreads();
    }

    if (lid == 0) {
        ptr = atomicAdd(results, (unsigned long long int)shuffle_ptr);
    }

    ptr = __shfl_sync(__activemask(), ptr, 0);

    if (lid < shuffle_ptr) {
        auto w_pos = (ptr + lid) % circular_buffer_size;
        if(lid < SHUFFLE_SIZE) {
            r_output[w_pos] = warp_shuffle->val_R_elem[lid];
            s_output[w_pos] = warp_shuffle->val_S_elem[lid];
            //keys_out[w_pos] = warp_shuffle->key_elem[lid];
        }
    }
}