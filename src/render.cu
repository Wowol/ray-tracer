#include "camera.h"
#include "color.h"
#include "ray.h"
#include "rectangle.h"
#include "render.h"
#include "vector3.h"
#include <limits>
#include <vector>

static constexpr int CHUNK_SIZE = 32;
static constexpr int MAX_NUMBER_OF_REFLECTIONS = 2;
static constexpr float FLOAT_INFINITY = std::numeric_limits<float>::max();

#define gpuErrchk(ans)                                                         \
    { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line,
                      bool abort = true) {
    if (code != cudaSuccess) {
        fprintf(stderr, "GPUassert: %s %s %d\n", cudaGetErrorString(code), file,
                line);
        if (abort)
            exit(code);
    }
}

static __device__ Ray reflect(Ray const &ray, Sphere const &sphere) {
    Vector3 intersection_point = sphere.get_intersection_point(ray);
    Vector3 perpendicular(sphere.get_position(), intersection_point);
    perpendicular.normalize();

    Vector3 oc(ray.get_position(), sphere.get_position());

    Vector3 offset(ray.get_position(),
                   perpendicular * (perpendicular.scalar_product(oc)));

    return Ray(intersection_point, ray.get_position() + offset * 2);
}

static __device__ RGBColor cast_ray(Ray ray, Sphere *spheres,
                                    int const &spheres_count) {

    int hit_sphere = -1;
    for (int i = 0; i < MAX_NUMBER_OF_REFLECTIONS; i++) {
        float current_distance = FLOAT_INFINITY;

        for (int sphere_index = 0; sphere_index < spheres_count;
             sphere_index++) {
            if (sphere_index != hit_sphere &&
                spheres[sphere_index].hits_ray(ray)) {
                float distance =
                    Vector3(ray.get_position(),
                            spheres[sphere_index].get_intersection_point(ray))
                        .length();
                if (distance < current_distance) {
                    current_distance = distance;
                    hit_sphere = sphere_index;
                }
            }
        }

        if (hit_sphere != -1) {
            ray = reflect(ray, spheres[hit_sphere]);
        } else {
            break;
        }
    }

    if (hit_sphere != -1) {
        return spheres[hit_sphere].get_material().get_color();
    }

    return RGBColor(0, 0, 0); // background
}

static __global__ void kernel(int width, int height, RGBColor *img,
                              Sphere *spheres, Camera camera,
                              int spheres_count) {
    int tidX = blockIdx.x * blockDim.x + threadIdx.x;
    int tidY = blockIdx.y * blockDim.y + threadIdx.y;
    if (tidX > width || tidY > height) {
        return;
    }

    img[tidY * width + tidX] = RGBColor(0.0f, 0.0f, 0.0f);

    Rectangle screen = camera.get_screen();

    Vector3 point_on_screen =
        Vector3(screen.left_top_point.x + tidX * screen.width() / width,
                screen.left_top_point.y - tidY * screen.height() / height,
                screen.left_top_point.z);
    Vector3 direction(camera.position, point_on_screen);
    Ray ray(camera.position, direction);

    img[tidY * width + tidX] = cast_ray(ray, spheres, spheres_count);
}

Image render(std::vector<Sphere> const &spheres, Camera &camera) {
    cudaSetDevice(0);
    Image img(1920, 1080);

    RGBColor *cudaPixels;
    gpuErrchk(
        cudaMalloc(&cudaPixels, sizeof(RGBColor) * img.width() * img.height()));

    Sphere *cudaSpheres;
    gpuErrchk(cudaMalloc(&cudaSpheres, sizeof(Sphere) * spheres.size()));
    gpuErrchk(cudaMemcpy(cudaSpheres, spheres.data(),
                         sizeof(Sphere) * spheres.size(),
                         cudaMemcpyHostToDevice));

    uint32_t gridX = (img.width() + CHUNK_SIZE - 1) / CHUNK_SIZE;
    uint32_t gridY = (img.height() + CHUNK_SIZE - 1) / CHUNK_SIZE;

    kernel<<<{gridX, gridY}, {CHUNK_SIZE, CHUNK_SIZE}>>>(
        img.width(), img.height(), cudaPixels, cudaSpheres, camera,
        spheres.size());

    gpuErrchk(cudaDeviceSynchronize());

    gpuErrchk(cudaMemcpy(img.raw(), cudaPixels,
                         sizeof(RGBColor) * img.width() * img.height(),
                         cudaMemcpyDeviceToHost));
    cudaFree(cudaPixels);
    cudaFree(cudaSpheres);

    return img;
}
