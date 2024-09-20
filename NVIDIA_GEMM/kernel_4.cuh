#pragma once

#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <stdio.h>
#include <stdlib.h>

#define OFFSET(row, col, ld) ((row)*(ld)+(col))
#define FETCH_FLOAT4(pointer) (reinterpret_cast<float4*>(&(pointer))[0])

template<const int BM,
    const int BN,
    const int BK,
    const int TM,
    const int TN>
__global__ void doubleBuffering(int M, int N, int K, float alpha, float* A, float* B, float beta, float* C) {
    int bx = blockIdx.x;
    int by = blockIdx.y;

    const int block_row_thread = BN / TN;
    const int block_col_thread = BM / TM;
    const int thread_num = block_row_thread * block_col_thread; // һ���̸߳������block��TM*TN��Ԫ��   TM*TN=8*8=64

    // ��ǰ�̶߳�Ӧthread tile�����Ͻ�Ԫ����block�е�λ��
    int tx = (threadIdx.x % block_row_thread) * TN;
    int ty = (threadIdx.x / block_row_thread) * TM;

    __shared__ float As[2][BK * BM]; // ����һ�������ڴ��С���ڻ���
    __shared__ float Bs[2][BK * BN];


    const int ldg_a_num = BK * BM / thread_num / 4; // ÿ���̰߳���4������������ɰ�����As��Ҫ�����̰߳���ldg_a_num��
    const int ldg_b_num = BK * BN / thread_num / 4; // ÿ���̰߳���4������������ɰ�����Bs��Ҫ�����̰߳���ldg_b_num��

    int a_tile_row = threadIdx.x / (BK / 4); // ÿ��4���ֽ���Ϊһ���ڴ�飬��ǰ�̸߳����a_tile_row�еĵ�a_tile_col���ڴ��İ���
    int a_tile_col = threadIdx.x % (BK / 4) * 4;
    int a_tile_stride = BM / ldg_a_num; // һ��BM�У�����ldg_a_num�֣�ÿ�ְ���a_tile_stride��

    int b_tile_row = threadIdx.x / (BN / 4); // ÿ��4���ֽ���Ϊһ���ڴ�飬��ǰ�̸߳����b_tile_row�еĵ�b_tile_col���ڴ��İ���
    int b_tile_col = threadIdx.x % (BN / 4) * 4;
    int b_tile_stride = BK / ldg_b_num; // һ��BK�У�����ldg_b_num�֣�ÿ�ְ���b_tile_stride��

    float accum[TM][TN] = { 0. }; // ÿ���̸߳���TM*TN��Ԫ�أ�����Ҫ����TM*TN���Ĵ��������ۼ�ֵ�������һ���Ĵ������ڻ��棻

    // ����ldg_a_num�����в�������ȫ����const���������������������С
    float ldg_a_reg[4 * ldg_a_num] = { 0. }; // ÿ���̰߳���ldg_a_num�֣��Ĵ�������ldg_a_num��float4Ԫ�أ�����ת��As����       //Reg1
    float ldg_b_reg[4 * ldg_b_num] = { 0. }; // ÿ���̰߳���ldg_a_num�֣��Ĵ�������ldg_a_num��float4Ԫ�أ�����ת��As����

    float a_frag[2][TM];  // ����As�����ڴ�,����һ���Ĵ�����С���ڻ���     //Reg2
    float b_frag[2][TN];  // ����Bs�����ڴ�,����һ���Ĵ�����С���ڻ���

    // �ƶ�����ǰblock
    A = &A[by * BM * K];
    B = &B[bx * BN];
    C = &C[by * BM * N + bx * BN];

    // float4�Ż�����
    // first global to shared           //ȫ�ֵ�����
#pragma unroll
    for (int i = 0; i < BM; i += a_tile_stride) {
        int ldg_index = i / a_tile_stride * 4;  // ��ldg_index��
        FETCH_FLOAT4(ldg_a_reg[ldg_index]) =
            FETCH_FLOAT4(A[OFFSET(a_tile_row + i, a_tile_col, K)]);
        // Asת�ô棬����ldg_a_reg���м仺�棬Ŀ���Ƕ�ȡʱ���԰�FLOAT4��ȡ
        As[0][OFFSET(a_tile_col, i + a_tile_row, BM)] = ldg_a_reg[ldg_index];
        As[0][OFFSET(a_tile_col + 1, i + a_tile_row, BM)] = ldg_a_reg[ldg_index + 1];
        As[0][OFFSET(a_tile_col + 2, i + a_tile_row, BM)] = ldg_a_reg[ldg_index + 2];
        As[0][OFFSET(a_tile_col + 3, i + a_tile_row, BM)] = ldg_a_reg[ldg_index + 3];
    }
#pragma unroll
    for (int i = 0; i < BK; i += b_tile_stride) {
        FETCH_FLOAT4(Bs[0][OFFSET(b_tile_row + i, b_tile_col, BN)]) =
            FETCH_FLOAT4(B[OFFSET(b_tile_row + i, b_tile_col, N)]); // ����Ҫת��
    }
    __syncthreads();

    // first shared to frag             //��������Ĵ���      //// first shared to Reg2
#pragma unroll      
    for (int m = 0; m < TM; m += 4) {
        FETCH_FLOAT4(a_frag[0][m]) = FETCH_FLOAT4(As[0][OFFSET(0, ty + m, BM)]); // ƫ�Ƶ���ǰthread tile
    }
#pragma unroll
    for (int n = 0; n < TN; n += 4) {
        FETCH_FLOAT4(b_frag[0][n]) = FETCH_FLOAT4(Bs[0][OFFSET(0, tx + n, BN)]); // ƫ�Ƶ���ǰthread tile
    }

    // ˫�����Ż�����

    int write_index = 1;
    int load_index;
    int k = 0;
    do {
        k += BK;
        // load global to reg   //ȫ�ֵ�����Ĵ���
        if (k < K) {
#pragma unroll      //Aȫ�ֵ�����Ĵ���     //Load Global, Store Reg1
            for (int i = 0; i < BM; i += a_tile_stride) {
                int ldg_index = i / a_tile_stride * 4;  // ��ldg_index��
                FETCH_FLOAT4(ldg_a_reg[ldg_index]) =
                    FETCH_FLOAT4(A[OFFSET(a_tile_row + i, k + a_tile_col, K)]);
            }
#pragma unroll      //Bȫ�ֵ�����Ĵ���
            for (int i = 0; i < BK; i += b_tile_stride) {
                int ldg_index = i / b_tile_stride * 4;  // ��ldg_index��
                FETCH_FLOAT4(ldg_b_reg[ldg_index]) =
                    FETCH_FLOAT4(B[OFFSET(k + b_tile_row + i, b_tile_col, N)]);
            }
        }

        load_index = write_index ^ 1;   //�л�������
        //���㲿��
#pragma unroll      //����Asд��Ĵ���     //Load Shared, Store Reg2
        for (int bk = 0; bk < BK - 1; bk++) {   //load��д��Ĵ�����write����
            for (int m = 0; m < TM; m += 4) {
                FETCH_FLOAT4(a_frag[(bk + 1) % 2][m]) = FETCH_FLOAT4(
                    As[load_index][OFFSET(bk + 1, ty + m, BM)]); // ƫ�Ƶ���ǰthread tile
            }
#pragma unroll      //����Bsд��Ĵ���
            for (int n = 0; n < TN; n += 4) {
                FETCH_FLOAT4(b_frag[(bk + 1) % 2][n]) = FETCH_FLOAT4(
                    Bs[load_index][OFFSET(bk + 1, tx + n, BN)]); // ƫ�Ƶ���ǰthread tile
            }
#pragma unroll      //�ۼӽ��������accum�Ĵ���       //FMA
            for (int m = 0; m < TM; m++) {
                for (int n = 0; n < TN; n++) {
                    accum[m][n] += a_frag[bk % 2][m] * b_frag[bk % 2][n];
                }
            }
        }
        if (k < K) {
#pragma unroll      //Load Reg1, Store Shared
            for (int i = 0; i < BM; i += a_tile_stride) {
                int ldg_index = i / a_tile_stride * 4;
                As[write_index][OFFSET(a_tile_col, i + a_tile_row, BM)] = ldg_a_reg[ldg_index];
                As[write_index][OFFSET(a_tile_col + 1, i + a_tile_row, BM)] = ldg_a_reg[ldg_index + 1];
                As[write_index][OFFSET(a_tile_col + 2, i + a_tile_row, BM)] = ldg_a_reg[ldg_index + 2];
                As[write_index][OFFSET(a_tile_col + 3, i + a_tile_row, BM)] = ldg_a_reg[ldg_index + 3];
            }
#pragma unroll      //����Ĵ���д�빲����һ��������
            for (int i = 0; i < BK; i += b_tile_stride) {
                int ldg_index = i / b_tile_stride * 4;
                FETCH_FLOAT4(Bs[write_index][OFFSET(b_tile_row + i, b_tile_col, BN)]) =
                    FETCH_FLOAT4(ldg_b_reg[ldg_index]);
            }
            __syncthreads();
            //���㲿��
#pragma unroll      //Load Shared, Store Reg2
            for (int m = 0; m < TM; m += 4) {
                FETCH_FLOAT4(a_frag[0][m]) = FETCH_FLOAT4(
                    As[write_index][OFFSET(0, ty + m, BM)]); // ƫ�Ƶ���ǰthread tile
            }
#pragma unroll
            for (int n = 0; n < TN; n += 4) {
                FETCH_FLOAT4(b_frag[0][n]) = FETCH_FLOAT4(
                    Bs[write_index][OFFSET(0, tx + n, BN)]); // ƫ�Ƶ���ǰthread tile
            }

            write_index ^= 1;
        }
#pragma unroll      //�ۼӽ��������accum�Ĵ���
        for (int m = 0; m < TM; m++) {      //FMA
#pragma unroll
            for (int n = 0; n < TN; n++) {
                accum[m][n] += a_frag[(BK - 1) % 2][m] * b_frag[(BK - 1) % 2][n];
            }
        }


    } while (k < K);

    // C = alpha*AB+C
#pragma unroll      //��������д�ص�ȫ���ڴ�
    for (int m = 0; m < TM; m++) {
#pragma unroll
        for (int n = 0; n < TN; n += 4) {
            float4 ctmp = FETCH_FLOAT4(C[OFFSET(ty + m, tx + n, N)]);
            ctmp.x = alpha * accum[m][n] + beta * ctmp.x;
            ctmp.y = alpha * accum[m][n + 1] + beta * ctmp.y;
            ctmp.z = alpha * accum[m][n + 2] + beta * ctmp.z;
            ctmp.w = alpha * accum[m][n + 3] + beta * ctmp.w;
            FETCH_FLOAT4(C[OFFSET(ty + m, tx + n, N)]) = ctmp;
        }
    }
}