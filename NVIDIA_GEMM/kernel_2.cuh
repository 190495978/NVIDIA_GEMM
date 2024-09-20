#pragma once

#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <stdio.h>
#include <stdlib.h>

#define M 16384 
#define K 16384
#define N 16384
#define BLOCK_SIZE 32 
using namespace std;

__global__ void Shared(float* A, float* B, float* C, int numARows,    //����˼���ǽ����� A �� B ��Ϊ��СΪ BLOCK_SIZE x BLOCK_SIZE �ľֲ��飬���ù����ڴ�洢��Щ�ֲ����ݣ�Ȼ�������̼߳���ֲ�����˷����ۼӽ����
    int numAColumns, int numBRows,
    int numBColumns, int numCRows,
    int numCColumns) {
    __shared__ float ds_M[BLOCK_SIZE][BLOCK_SIZE];
    __shared__ float ds_N[BLOCK_SIZE][BLOCK_SIZE];
    int bx = blockIdx.x;
    int by = blockIdx.y;
    int tx = threadIdx.x;
    int ty = threadIdx.y;
    int Row = by * BLOCK_SIZE + ty;
    int Col = bx * BLOCK_SIZE + tx;
    float Pvalue = 0;
    for (int m = 0; m < (numAColumns - 1) / BLOCK_SIZE + 1; ++m) {
        if (Row < numARows && m * BLOCK_SIZE + tx < numAColumns) {  //������ A �ľֲ����ݼ��ص������ڴ����� ds_M�������ǰ�߳��������Ԫ��λ�ھ��� A ����Ч��Χ�ڣ���Ӿ��� A �ж�ȡ��ӦԪ�أ����򣬽� ds_M �ж�Ӧλ����Ϊ 0.0��
            ds_M[ty][tx] = A[Row * numAColumns + m * BLOCK_SIZE + tx];
        }
        else {
            ds_M[ty][tx] = 0.0;
        }
        if (Col < numBColumns && m * BLOCK_SIZE + ty < numBRows) {
            ds_N[ty][tx] = B[(m * BLOCK_SIZE + ty) * numBColumns + Col];
        }
        else {
            ds_N[ty][tx] = 0.0;
        }
        __syncthreads();    //ͬ���̣߳�ȷ�������߳�����ɴӾ��� A �� B �м������ݵ������ڴ档
        for (int k = 0; k < BLOCK_SIZE; ++k) {  //�ڲ�ѭ��ִ�оֲ�����˷���������ǰ�̸߳���Ĺ����ڴ� ds_M ��һ�к� ds_N ��һ�У�ִ�е�˲�������ۼӵ� Pvalue��
            Pvalue += ds_M[ty][k] * ds_N[k][tx];
        }
        __syncthreads();    //�ٴ�ͬ���̣߳�ȷ�������߳�����ɾֲ�����˷����Ա������һ�ֵ�����
    }
    if (Row < numCRows && Col < numCColumns) {
        C[Row * numCColumns + Col] = Pvalue;
    }
}
