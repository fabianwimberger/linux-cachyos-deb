// Sustained SGEMM through rocBLAS, for the ROCm phase of profile-load.sh.
//
//   gemm [n] [seconds]
//
// Compiled inside the ROCm container with `hipcc -O2 gemm.cpp -lrocblas`. What
// matters for a kernel profile is the submission path: every iteration
// synchronises, so each GEMM is a queue submission, a fence wait and a wakeup
// through amdgpu/KFD, and every 16th result is copied back to exercise DMA.
#include <hip/hip_runtime.h>
#include <rocblas/rocblas.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <vector>

#define CHECK(expr)                                                     \
    do {                                                                \
        if ((expr) != 0) {                                              \
            std::fprintf(stderr, "%s failed at line %d\n", #expr, __LINE__); \
            return 1;                                                   \
        }                                                               \
    } while (0)

int main(int argc, char **argv) {
    const int n = argc > 1 ? std::atoi(argv[1]) : 4096;
    const double seconds = argc > 2 ? std::atof(argv[2]) : 60.0;
    const size_t count = size_t(n) * n;
    const size_t bytes = count * sizeof(float);

    std::vector<float> host(count, 1.0f);
    float *a, *b, *c;
    CHECK(hipMalloc(&a, bytes));
    CHECK(hipMalloc(&b, bytes));
    CHECK(hipMalloc(&c, bytes));
    CHECK(hipMemcpy(a, host.data(), bytes, hipMemcpyHostToDevice));
    CHECK(hipMemcpy(b, host.data(), bytes, hipMemcpyHostToDevice));

    rocblas_handle handle;
    CHECK(rocblas_create_handle(&handle));
    const float alpha = 1.0f, beta = 0.0f;

    const auto end = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    long iterations = 0;
    while (std::chrono::steady_clock::now() < end) {
        CHECK(rocblas_sgemm(handle, rocblas_operation_none, rocblas_operation_none,
                            n, n, n, &alpha, a, n, b, n, &beta, c, n));
        CHECK(hipDeviceSynchronize());
        if (++iterations % 16 == 0)
            CHECK(hipMemcpy(host.data(), c, bytes, hipMemcpyDeviceToHost));
    }

    std::printf("%ld sgemm %dx%d in %.0fs\n", iterations, n, n, seconds);
    rocblas_destroy_handle(handle);
    (void)hipFree(a);
    (void)hipFree(b);
    (void)hipFree(c);
    return 0;
}
