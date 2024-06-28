#pragma once
#include <vector>
#include <memory>

#include "mperf.h"
#include "mmath.h"
#include "CudaSimulator.h"
#include "CpuSimulator.h"

typedef void (*Emitter)(
    double *u, double *v, double *w,
    double *u0, double *v0, double *w0,
    double *density,
    double *density0,
    double *temperature,
    double *temperature0,
    double *pressure);

class Simulator
{
public:
  EIGEN_MAKE_ALIGNED_OPERATOR_NEW

  Simulator(double &time);
  ~Simulator() = default;

  void update();

  const double *getDensity()
  {
    return density;
  }

  const std::string getPerformanceInfo()
  {
    auto time_str = get_mesaurement_info();
    // get solver info
    int iter;
    double error;
    // CudaSim.solver_.getIterations(iter);
    // CudaSim.solver_.getError(error);
    return time_str + "Solver Iterations: " +
           std::to_string(iter) + " Solver Error: " + std::to_string(error) + "\n";
  }

  void setOccupiedVoxels(std::array<bool, SIZE> &occupied_voxels)
  {
    m_occupied_voxels = occupied_voxels;
  }

  void setEnvTemperature(double temp)
  {
    envTemp_ = temp;
  }

  void setAlpha(double alpha)
  {
    alpha_ = alpha;
  }

  void setBeta(double beta)
  {
    beta_ = beta;
  }

  void setVortEps(double vort_eps)
  {
    vort_eps_ = vort_eps;
  }

  void setDecayFactor(double decay_factor)
  {
    decay_factor_ = decay_factor;
  }

  void setDt(double dt)
  {
    dt_ = dt;
    CudaSim.setDt(dt);
    CPUSim.setDt(dt);
  }

  void setEmitter(Emitter emitter)
  {
    this->emitter = emitter;
  }

  void reset()
  {
    for (int i = 0; i < SIZE; ++i)
    {
      density[i] = 0.0;
      density0[i] = 0.0;
      temperature[i] = envTemp_;
      temperature0[i] = envTemp_;
      pressure[i] = 0.0;
      u[i] = 0.0;
      u0[i] = 0.0;
      v[i] = 0.0;
      v0[i] = 0.0;
      w[i] = 0.0;
      w0[i] = 0.0;
    }

    m_time = 0.0;
  }

private:
  double &m_time;
  double dt_ = DT;
  double envTemp_ = T_AMBIENT;
  double alpha_ = ALPHA;
  double beta_ = BETA;
  double vort_eps_ = VORT_EPS;
  double decay_factor_ = 0.99;

  Emitter emitter;

  void update_gpu();
  void update_cpu();

  void applyOccupiedVoxels();

  // external force
  double fx[SIZE], fy[SIZE], fz[SIZE];
  // velocity field
  double u[SIZE], u0[SIZE];
  double v[SIZE], v0[SIZE];
  double w[SIZE], w0[SIZE];
  double avg_u[SIZE], avg_v[SIZE], avg_w[SIZE];

  // vorticity field
  double omg_x[SIZE], omg_y[SIZE], omg_z[SIZE];

  // pressure field
  double pressure[SIZE];

  // temperature field
  double temperature0[SIZE], temperature[SIZE];

  // density field
  double density[SIZE], density0[SIZE];

  MCUDA::CudaSimulator CudaSim;

  CPUSIM::CpuSimulator CPUSim;

  // ocuppied voxels
  std::array<bool, SIZE>
      m_occupied_voxels;
};