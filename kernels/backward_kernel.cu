#include <cuda.h>
#include "flash_attn_kernel.h"


__global__ void backward_kernel(float *Q, float *K, float *V, float *O, float* dQ, float* dK, float* dV, float* dO, float *l,
                              float *m, const int N, const int d, const int block_size, const int Tc, const int Tr) {
    
    // Given Q, K, V, O, dO, l, m we need to compute dQ, dK, dV
    // 
    // Q, K, V: query, key, value (N * d)
    // O, output: (N * d)
    // l, m: intermediate states (N)

    // N: sequence length <int>(scaler)
    // d: dimention <int>(scaler)
    // block_size: number of col/row per block
    // Tc, Tr: number of blocks 
 
    int batch_id = blockIdx.x;
    int head_id = blockIdx.y;
    int thread_id = threadIdx.x;
    int num_heads = gridDim.y;
    int tile_size = blockDim.x; //num_threads=tile_size

    // Differnt offset for different (batch, head)
    int qkvo_offset = (batch_id * num_heads * N * d) + (head_id * N * d);
    int lm_offset = (batch_id * num_heads * N) + (head_id * N);

    extern __shared__ float sram[];
    //K, V, Q, O, dK, dV, dO has size=block_size * d
    //SPij, dSPij has size=block_size * block_size
    float * const smem_Kj = &sram[0]; 
    float * const smem_Vj = &sram[block_size * d]; 
    float * const smem_Oi = &sram[block_size * d * 2]; 
    float * const smem_Qi = &sram[block_size * d * 3];
    float * const smem_dKj = &sram[block_size * d * 4];  
    float * const smem_dVj = &sram[block_size * d * 5];
    float * const smem_dOi = &sram[block_size * d * 6];
    float * const smem_SPij = &sram[block_size * d * 7];
    float * const smem_dSPij = &sram[block_size * d * 7 + block_size * block_size];
    
    int offset_si = block_size * thread_id;


    for (int j = 0; j < Tc; ++j) {
      // Load Kj, Vj to shared memory
      if ((j * block_size + thread_id) < N) { // Make sure global col < seq_len 
        for (int x = 0; x < d; x += 1) {
            smem_Kj[thread_id * d + x] = K[qkvo_offset + (j * block_size * d) + (thread_id * d) + x];
            smem_Vj[thread_id * d + x] = V[qkvo_offset + (j * block_size * d) + (thread_id * d) + x];
            // printf("thread=%d, load q=%f\n", thread_id, smem_Kj[offset_si + c]);
            // printf("thread=%d, load k=%f\n", thread_id, smem_Vj[offset_si + c]);
        }
      }
      // Initialize dKj, dVj on shared_memory 
      for (int x = 0; x < d; x += 1) {
        smem_dKj[thread_id * d + x] = 0;
        smem_dVj[thread_id * d + x] = 0;
      } 
      __syncthreads();

      const int num_cols = min(block_size, N - (block_size * j));

      for (int i = 0; i < Tr; ++i) {
        if ((i * block_size + thread_id) < N) { // Make sure global col < seq_len 
          // Load Qi, dOi to register 
          for (int x = 0; x < d; x += 1) {
              smem_Qi[thread_id * d + x] = Q[qkvo_offset + (i * block_size * d) + (thread_id * d) + x];
              smem_Oi[thread_id * d + x] = O[qkvo_offset + (i * block_size * d) + (thread_id * d) + x];
              smem_dOi[thread_id * d + x] = dO[qkvo_offset + (i * block_size * d) + (thread_id * d) + x];
              // printf("thread=%d, load q=%f\n", thread_id, smem_Kj[offset_si + c]);
              // printf("thread=%d, load k=%f\n", thread_id, smem_Vj[offset_si + c]);
          }
        
          // Load li, mi from HBM to register
          float li = l[lm_offset + (i * block_size) + thread_id];
          float mi = m[lm_offset + (i * block_size) + thread_id];

          // Compute Sij
          // Sij = Qi * Kj 
          for (int c = 0; c < num_cols; c += 1) {
              // smem_SPij[offset_si + c] = 0;
              // printf("rewrite offset=%d\n", offset_si + c);
              float row_sum = 0;
              for (int x = 0; x < d; x += 1) {
                  row_sum += (smem_Qi[thread_id * d + x] * smem_Kj[c * d + x]);
                  // printf("thread=%d, (c, x)=(%d, %d), q-read from sram[%d], compute q*k=%f*%f\n", 
                  //     thread_id, c, x, (2 * Bc * d) + (thread_id * d + x), smem_Qi[thread_id * d + x], smem_Kj[c * d + x]);
              }
              // printf("thread=%d, writes: %f to sram[%d] Sij_off=%d + %d (Bc=%d, Br=%d, d=%d)\n", 
              //     thread_id, row_sum, (Bc * d + Bc * d + Br * d) + offset_si + c, (Bc * d + Bc * d + Br * d), offset_si + c, Bc, Br, d); 
              smem_SPij[offset_si + c] = row_sum;
          }

          // Compute Pij 
          // Pij = 1/li * Sij
          for (int c = 0; c < num_cols; c += 1) {
            smem_SPij[offset_si + c] = __expf(smem_SPij[offset_si + c] - mi) / li;
          }

          // Update dVj
          // dVj += Pij_transpose * dOi
          for (int x = 0; x < d; x += 1) {
            float row_sum = 0;
            for (int c = 0; c < num_cols; c += 1) {
              row_sum += smem_SPij[c * block_size + thread_id] * smem_dOi[c * block_size + x];
            }
            smem_dVj[thread_id * d + x] += row_sum; 
          }

          // Compute dPij 
          // dPij = dOi * Vj_transpose
          for (int c = 0; c < num_cols; c += 1) {
            float row_sum = 0;
            for (int x = 0; x < d; x += 1) {
              row_sum += smem_dOi[thread_id * d + x] * smem_Vj[c * block_size + x];
            }  
            smem_dSPij[thread_id * block_size + c] = row_sum;
          }
          
          // Compute dSij 
          // Di = row_sum(dOi o Oi) 
          // dSij = Pij o (dPij - Di)
          float Di = 0;
          for (int x = 0; x < d; x += 1) {
            Di += smem_dOi[thread_id * d + x] * O[thread_id * d + x];
          } 
          for (int c = 0; c < num_cols; c += 1){
            smem_dSPij[thread_id * block_size + c] = smem_SPij[thread_id * block_size + c] * (smem_dSPij[thread_id * block_size + c] - Di);
          }

          // Write updated dQi to HBM 
          // dQi += dSij * Kj
          for (int x = 0; x < d; x += 1) {
            float row_sum = 0;
            for (int c = 0; c < num_cols; c += 1) {
              row_sum += smem_dSPij[thread_id * block_size + d] * smem_Kj[c * d + x];
            }
            dQ[qkvo_offset + (i * block_size * d) + (thread_id * d) + x] = row_sum; 
          }
          
          // Update dKj 
          // dKj += dSij_transpose * Qi
          for (int x = 0; x < d; x += 1) {
            float row_sum = 0;
            for (int c = 0; c < num_cols; c += 1) {
              row_sum += smem_dSPij[thread_id * x + c] * smem_Qi[thread_id * c + x]; 
            }
            smem_dKj[thread_id * d + x] = row_sum;
          }
        }
        // Make sure Qi, O, dOi load correctly
        __syncthreads(); 
      }
      // Write dKj, dVj to HBM 
      if ((j * block_size + thread_id) < N) { // Make sure global col < seq_len 
        for (int x = 0; x < d; x += 1) {
           dK[qkvo_offset + (j * block_size * d) + (thread_id * d) + x] = smem_dKj[thread_id * d + x];
           dV[qkvo_offset + (j * block_size * d) + (thread_id * d) + x] =  smem_dVj[thread_id * d + x];
        }
      }
    }

}

inline void CHECK_CUDA_ERROR() {                                          
    cudaError_t err = cudaGetLastError();                            
    if (err != cudaSuccess) {                                         
        std::cerr << "CUDA error: " << cudaGetErrorString(err) << std::endl; 
        exit(err);                                                    
    }                                                                 
}

void lanuch_backward_kernel(torch::Tensor Q, torch::Tensor K, torch::Tensor V, torch::Tensor O, torch::Tensor dQ, torch::Tensor dK, torch::Tensor dV, torch::Tensor dO, torch::Tensor l, torch::Tensor m) {
    // 
    int batch_size = Q.size(0);
    int num_heads = Q.size(1);
    int N = Q.size(2);
    int d = Q.size(3);
    printf("Batch=%d, Head=%d, SeqLen=%d, EmbDim=%d\n", batch_size, num_heads, N, d);
    //
    int max_shared_memory;
    int max_threads_num;
    cudaDeviceGetAttribute(&max_shared_memory, cudaDevAttrMaxSharedMemoryPerBlock, 0);
    cudaDeviceGetAttribute(&max_threads_num, cudaDevAttrMaxThreadsPerBlock, 0);
    
    // Fix Tile size
    const int block_size = 32;
    int Bc = block_size;        
    int Br = block_size;
    int Tc = std::ceil(N/Bc);
    int Tr = std::ceil(N/Br);

    dim3 grid_dim(batch_size, num_heads);
    dim3 thread_block_dim(block_size);
    // shared_memory_size
    // For: Kj, Vj, Qi, Oi, dKj, dVj dOi, Sij dSij 

    const int shared_memory_size = sizeof(float) * ((7 * block_size * d) + (2 * block_size * block_size));
    
    printf("Max_shared(bytes)=%d, Requested_memory(bytes)=%d\n", max_shared_memory, shared_memory_size);
    TORCH_CHECK(shared_memory_size < max_shared_memory, "Shared memory size exceeds the device limit"); 
    
    printf("N=%d, d=%d, block_size=%d, Tc=%d, Tr=%d\n", N, d, block_size, Tc, Tr);
    // printf("Start Position: K=0, V=%d, Q=%d, S=%d\n", Bc * d, 2 * Bc * d, (2 * Bc * d) + (Br * d));
    // Launch
    backward_kernel<<<grid_dim, thread_block_dim, shared_memory_size>>>(
        Q.data_ptr<float>(), K.data_ptr<float>(), V.data_ptr<float>(), O.data_ptr<float>(), 
        dQ.data_ptr<float>(), dK.data_ptr<float>(), dV.data_ptr<float>(), dO.data_ptr<float>(), 
        l.data_ptr<float>(), m.data_ptr<float>(), 
        N, d, block_size, Tc, Tr
    );
    
    CHECK_CUDA_ERROR();
}

