#include "Solver.h"

#include <stdio.h>
#include <stdlib.h>

#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <cusparse.h>

#define checkCudaErrors(err)                                         \
    if (err != cudaSuccess)                                          \
    {                                                                \
        printf("CUDA error\n");                                      \
        printf("Error at line %d in file %s\n", __LINE__, __FILE__); \
        exit(1);                                                     \
    }

void CudaSolver::compute(
    Eigen::SparseMatrix<double, Eigen::RowMajor> &A)
{
    N = A.rows();
    nz = A.nonZeros();
    I = A.outerIndexPtr();
    J = A.innerIndexPtr();
    val = A.valuePtr();

    cublasStatus = cublasCreate(&cublasHandle);
    checkCudaErrors(cublasStatus);

    /* Get handle to the CUSPARSE context */
    checkCudaErrors(cusparseCreate(&cusparseHandle));

    checkCudaErrors(cudaMalloc((void **)&d_col, nz * sizeof(int)));
    checkCudaErrors(cudaMalloc((void **)&d_row, (N + 1) * sizeof(int)));
    checkCudaErrors(cudaMalloc((void **)&d_val, nz * sizeof(double)));
    checkCudaErrors(cudaMalloc((void **)&d_x, N * sizeof(double)));
    checkCudaErrors(cudaMalloc((void **)&d_r, N * sizeof(double)));
    checkCudaErrors(cudaMalloc((void **)&d_p, N * sizeof(double)));
    checkCudaErrors(cudaMalloc((void **)&d_Ax, N * sizeof(double)));

    /* Wrap raw data into cuSPARSE generic API objects */
    checkCudaErrors(cusparseCreateCsr(&matA, N, N, nz, d_row, d_col, d_val,
                                      CUSPARSE_INDEX_32I, CUSPARSE_INDEX_32I,
                                      CUSPARSE_INDEX_BASE_ZERO, CUDA_R_64F));

    checkCudaErrors(cusparseCreateDnVec(&vecx, N, d_x, CUDA_R_64F));
    checkCudaErrors(cusparseCreateDnVec(&vecp, N, d_p, CUDA_R_64F));
    checkCudaErrors(cusparseCreateDnVec(&vecAx, N, d_Ax, CUDA_R_64F));

    /* Initialize problem data */
    cudaMemcpy(d_col, J, nz * sizeof(int), cudaMemcpyHostToDevice);
    cudaMemcpy(d_row, I, (N + 1) * sizeof(int), cudaMemcpyHostToDevice);
    cudaMemcpy(d_val, val, nz * sizeof(double), cudaMemcpyHostToDevice);
}

void CudaSolver::getIterations(int &iter)
{
    iter = k;
}

void CudaSolver::getError(double &error)
{
    double rsum, diff, err = 0.0;

    for (int i = 0; i < N; i++)
    {
        rsum = 0.0;

        for (int j = I[i]; j < I[i + 1]; j++)
        {
            rsum += val[j] * x[J[j]];
        }

        diff = fabs(rsum - rhs[i]);

        if (diff > err)
        {
            err = diff;
        }
    }
    error = err;
}

void CudaSolver::solve_nocp(double *d_x, double *d_r)
{
    alpha = 1.0;
    alpham1 = -1.0;
    beta = 0.0;
    r0 = 0.;

    /* Allocate workspace for cuSPARSE */
    static void *buffer = NULL;
    {
        static bool do_one = true;
        if (do_one)
        {
            do_one = false;
            size_t bufferSize = 0;
            checkCudaErrors(cusparseSpMV_bufferSize(
                cusparseHandle, CUSPARSE_OPERATION_NON_TRANSPOSE, &alpha, matA, vecx,
                &beta, vecAx, CUDA_R_64F, CUSPARSE_SPMV_ALG_DEFAULT, &bufferSize));

            checkCudaErrors(cudaMalloc(&buffer, bufferSize));
        }
    }

    /* Begin CG */
    checkCudaErrors(cusparseSpMV(cusparseHandle, CUSPARSE_OPERATION_NON_TRANSPOSE,
                                 &alpha, matA, vecx, &beta, vecAx, CUDA_R_64F,
                                 CUSPARSE_SPMV_ALG_DEFAULT, buffer));

    cublasDaxpy(cublasHandle, N, &alpham1, d_Ax, 1, d_r, 1);
    cublasStatus = cublasDdot(cublasHandle, N, d_r, 1, d_r, 1, &r1);

    k = 1;
    // printf("tol * tol = %e\n", tol * tol);
    auto lowest = sqrt(r1);
    while (r1 > tol * tol && k <= max_iter)
    {
        if (k > 1)
        {
            b = r1 / r0;
            cublasStatus = cublasDscal(cublasHandle, N, &b, d_p, 1);
            cublasStatus = cublasDaxpy(cublasHandle, N, &alpha, d_r, 1, d_p, 1);
        }
        else
        {
            cublasStatus = cublasDcopy(cublasHandle, N, d_r, 1, d_p, 1);
        }

        checkCudaErrors(cusparseSpMV(
            cusparseHandle, CUSPARSE_OPERATION_NON_TRANSPOSE, &alpha, matA, vecp,
            &beta, vecAx, CUDA_R_64F, CUSPARSE_SPMV_ALG_DEFAULT, buffer));
        cublasStatus = cublasDdot(cublasHandle, N, d_p, 1, d_Ax, 1, &dot);
        a = r1 / dot;

        cublasStatus = cublasDaxpy(cublasHandle, N, &a, d_p, 1, d_x, 1);
        na = -a;
        cublasStatus = cublasDaxpy(cublasHandle, N, &na, d_Ax, 1, d_r, 1);

        r0 = r1;
        cublasStatus = cublasDdot(cublasHandle, N, d_r, 1, d_r, 1, &r1);
        cudaDeviceSynchronize();
        // printf("iteration = %3d, residual = %e\n", k, sqrt(r1));
        if (sqrt(r1) < lowest)
        {
            lowest = sqrt(r1);
        }

        k++;
    }
}

void CudaSolver::solve_from_gpu(
    double *xt,
    double *bt)
{
    // Device to device copy
    cudaMemcpy(d_r, bt, N * sizeof(double), cudaMemcpyDeviceToDevice);
    solve_nocp(d_x, d_r);
    cudaMemcpy(xt, d_x, N * sizeof(double), cudaMemcpyDeviceToDevice);
}

void CudaSolver::solve(
    double *xt,
    double *bt)
{
    /* Initialize problem data */
    // cudaMemcpy(d_x, x, N * sizeof(double), cudaMemcpyHostToDevice);
    cudaMemcpy(d_r, bt, N * sizeof(double), cudaMemcpyHostToDevice);

    solve_nocp(d_x, d_r);

    // copy result back to host
    cudaMemcpy(xt, d_x, N * sizeof(double), cudaMemcpyDeviceToHost);
}

void CudaSolver::solve(
    Eigen::VectorXd &xt,
    Eigen::VectorXd &bt)
{
    solve(xt.data(), bt.data());
}

CudaSolver::~CudaSolver()
{
    cusparseDestroy(cusparseHandle);
    cublasDestroy(cublasHandle);
    if (matA)
    {
        checkCudaErrors(cusparseDestroySpMat(matA));
    }
    if (vecx)
    {
        checkCudaErrors(cusparseDestroyDnVec(vecx));
    }
    if (vecAx)
    {
        checkCudaErrors(cusparseDestroyDnVec(vecAx));
    }
    if (vecp)
    {
        checkCudaErrors(cusparseDestroyDnVec(vecp));
    }

    cudaFree(d_col);
    cudaFree(d_row);
    cudaFree(d_val);

    cudaFree(d_x);
    cudaFree(d_r);
    cudaFree(d_p);
    cudaFree(d_Ax);
}