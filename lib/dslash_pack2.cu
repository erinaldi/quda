#include <typeinfo>
#include <color_spinor_field.h>
#include <color_spinor_field_order.h>
#include <color_spinor.h>

#define STRIPED
#ifdef STRIPED
#else
#define SWIZZLE // needs to be before index_helper is included
#endif

#include <dslash_helper.cuh>
#include <index_helper.cuh>
#include <dslash_quda.h>

namespace quda {

  static int commDim[QUDA_MAX_DIM];
  void setPackComms2(const int *comm_dim) {
    for (int i=0; i<4; i++) commDim[i] = comm_dim[i];
    for (int i=4; i<QUDA_MAX_DIM; i++) commDim[i] = 0;
  }

  template <typename Float_, int nColor_, int nSpin_>
  struct PackArg {

    typedef Float_ Float;

    static constexpr int nColor = nColor_;
    static constexpr int nSpin = nSpin_;

    static constexpr bool spin_project = (nSpin == 4 ? true : false);
    static constexpr bool spinor_direct_load = false; // false means texture load
    typedef typename colorspinor_mapper<Float,nSpin,nColor,spin_project,spinor_direct_load>::type F;

    const F field;     // field we are packing

    const int nFace;

    const bool dagger;

    const int parity;  // only use this for single parity fields
    const int nParity;  // number of parities we are working on

    const DslashConstant dc; // pre-computed dslash constants for optimized indexing

    int_fastdiv threads;
    int threadDimMapLower[4];
    int threadDimMapUpper[4];

    int_fastdiv swizzle;
    int sites_per_block;

    PackArg(void **ghost, const ColorSpinorField &field, int nFace, bool dagger, int parity)
      : field(field, 1, nullptr, nullptr, reinterpret_cast<Float**>(ghost)),
        nFace(nFace), dagger(dagger), parity(parity), nParity(field.SiteSubset()),
        dc(field.getDslashConstant())
    {
      if (!field.isNative()) errorQuda("Unsupported field order colorspinor=%d\n", field.FieldOrder());

      int sum = 0;
      for (int i=0; i<4; i++) {
        if (!commDim[i]) continue;
        if ( i==3 && !getKernelPackT() ) continue;
        sum += (2*nFace*field.GhostFace()[i]) / nParity; // 2 for forwards and backwards faces
      }
      threads = sum;

      int prev = -1; // previous dimension that was partitioned
      for (int i=0; i<4; i++) {
        threadDimMapLower[i] = 0;
        threadDimMapUpper[i] = 0;
        if (!commDim[i]) continue;
        threadDimMapLower[i] = (prev >= 0 ? threadDimMapUpper[prev] : 0);
        // divide by nParity since thread mapper is on checkerboard coords
        threadDimMapUpper[i] = threadDimMapLower[i] + (2*nFace*field.GhostFace()[i]) / nParity;
        prev=i;
      }
    }

  };

  template <typename Float, int nSpin, int nColor>
  std::ostream& operator<<(std::ostream& out, const PackArg<Float,nSpin,nColor> &arg)
  {
    out << "parity = " << arg.parity << std::endl;
    out << "nParity = " << arg.nParity << std::endl;
    out << "nFace = " << arg.nFace << std::endl;
    out << "dagger = " << arg.dagger << std::endl;
    out << "threads = " << arg.threads << std::endl;
    out << "threadDimMapLower = { ";
    for (int i=0; i<4; i++) out << arg.threadDimMapLower[i] << (i<3 ? ", " : " }"); out << std::endl;
    out << "threadDimMapUpper = { ";
    for (int i=0; i<4; i++) out << arg.threadDimMapUpper[i] << (i<3 ? ", " : " }"); out << std::endl;
    out << "sites_per_block = " << arg.sites_per_block << std::endl;
    return out;
  }

  template <bool dagger, int dim, typename Arg>
  __device__ __host__ inline void pack(Arg &arg, int ghost_idx, int parity) {

    typedef typename mapper<typename Arg::Float>::type real;
    typedef ColorSpinor<real,Arg::nColor,Arg::nSpin> Vector;
    typedef ColorSpinor<real,Arg::nColor,Arg::nSpin/2> HalfVector;
    constexpr int nFace = 1;

    int spinor_parity = (arg.nParity == 2) ? parity : 0;

    // compute where the output is located
    // compute an index into the local volume from the index into the face
    // read spinor, spin-project, and write half spinor to face

    // face_num determines which end of the lattice we are packing: 0 = start, 1 = end
    const int face_num = (ghost_idx >= nFace*arg.dc.ghostFaceCB[dim]) ? 1 : 0;
    ghost_idx -= face_num*nFace*arg.dc.ghostFaceCB[dim];

    // remove const to ensure we have non-const Ghost member
    typedef typename std::remove_const<decltype(arg.field)>::type T;
    T &field = const_cast<T&>(arg.field);

    if (face_num == 0) { // backwards

      int idx = indexFromFaceIndex<4,QUDA_4D_PC,dim,nFace,0>(ghost_idx, parity, arg);
      constexpr int proj_dir = dagger ? +1 : -1;
      Vector f = arg.field(idx, spinor_parity);
      field.Ghost(dim, 0, ghost_idx, spinor_parity) = f.project(dim, proj_dir);

    } else { // forwards

      int idx = indexFromFaceIndex<4,QUDA_4D_PC,dim,nFace,1>(ghost_idx, parity, arg);
      constexpr int proj_dir = dagger ? -1 : +1;
      Vector f = arg.field(idx, spinor_parity);
      field.Ghost(dim, 1, ghost_idx, spinor_parity) = f.project(dim, proj_dir);

    }

  }

  // FIXME - add CPU variant

  template <bool dagger, typename Arg>
  __global__ void packKernel(Arg arg)
  {

#ifdef STRIPED
    const int sites_per_block = arg.sites_per_block;
    int local_tid = threadIdx.x;
    int tid = sites_per_block * blockIdx.x + local_tid;
#else
    int tid = block_idx(arg.swizzle) * blockDim.x + threadIdx.x;
    constexpr int sites_per_block = 1;
    constexpr int local_tid = 0;
#endif
    // this is the parity used for load/store, but we use arg.parity for index mapping
    int parity = (arg.nParity == 2) ? blockDim.y*blockIdx.y + threadIdx.y : arg.parity;

    while ( local_tid < sites_per_block && tid < arg.threads ) {

      // determine which dimension we are packing
      int ghost_idx;
      const int dim = dimFromFaceIndex(ghost_idx, tid, arg);

      switch (dim) {
      case 0: pack<dagger,0>(arg, ghost_idx, parity); break;
      case 1: pack<dagger,1>(arg, ghost_idx, parity); break;
      case 2: pack<dagger,2>(arg, ghost_idx, parity); break;
      case 3: pack<dagger,3>(arg, ghost_idx, parity); break;
      }

#ifdef STRIPED
      local_tid += blockDim.x;
      tid += blockDim.x;
#else
      tid += blockDim.x*gridDim.x;
#endif
    } // while tid

  }

  template <typename Arg>
  class Pack : TunableVectorY {

  protected:
    Arg &arg;
    const ColorSpinorField &meta;
    MemoryLocation location;

#ifdef STRIPED
    bool tuneGridDim() const { return true; } // If striping, always tune grid dimension
    unsigned int maxGridSize() const {
      if (location & Host) {
	// if zero-copy policy then set a maximum number of blocks to be
	// the 3 * number of dimensions we are communicating
        int nDimComms = 0;
        for (int d=0; d<meta.Ndim(); d++) nDimComms += commDim[d];
        return 3*nDimComms;
      } else {
        return TunableVectorY::maxGridSize();
      }
    } // use no more than a quarter of the GPU
    unsigned int minGridSize() const {
      if (location & Host) {
	// if zero-copy policy then set a maximum number of blocks to be
	// the 1 * number of dimensions we are communicating
        int nDimComms = 0;
        for (int d=0; d<meta.Ndim(); d++) nDimComms += commDim[d];
        return nDimComms;
      } else {
        return TunableVectorY::minGridSize();
      }
    }
#else
    bool tuneGridDim() const { return location & Host; } // only tune grid dimension if doing zero-copy writing
    unsigned int maxGridSize() const { return tuneGridDim() ? deviceProp.multiProcessorCount/4 : TunableVectorY::maxGridSize(); } // use no more than a quarter of the GPU
#endif

    bool tuneAuxDim() const { return true; } // Do tune the aux dimensions.
    unsigned int minThreads() const { return arg.threads; }

    void fillAux() {
      strcpy(aux,"policy_kernel,");
      strcat(aux, meta.AuxString());
      char comm[5];
      comm[0] = (commDim[0] ? '1' : '0');
      comm[1] = (commDim[1] ? '1' : '0');
      comm[2] = (commDim[2] ? '1' : '0');
      comm[3] = (commDim[3] ? '1' : '0');
      comm[4] = '\0'; strcat(aux,",comm=");
      strcat(aux,comm);
      strcat(aux,comm_dim_topology_string());
      if (arg.dagger) { strcat(aux, "dagger"); }
      if (getKernelPackT()) { strcat(aux,",kernelPackT"); }
      switch (arg.nFace) {
      case 1: strcat(aux,",nFace=1,"); break;
      case 3: strcat(aux,",nFace=3,"); break;
      default: errorQuda("Number of faces not supported");
      }

      // label the locations we are packing to
      // location lable is nonp2p-p2p
      switch ((int)location) {
      case Device|Remote: strcat(aux,"device-remote"); break;
      case   Host|Remote: strcat(aux,  "host-remote"); break;
      case        Device: strcat(aux,"device-device"); break;
      case          Host: strcat(aux, comm_peer2peer_enabled_global() ? "host-device" : "host-host"); break;
      default: errorQuda("Unknown pack target location %d\n", location);
      }
    }

  public:

    Pack(Arg &arg, const ColorSpinorField &meta, MemoryLocation location)
      : TunableVectorY(meta.SiteSubset()), arg(arg), meta(meta), location(location)
    {
      fillAux();
    }

    virtual ~Pack() { }

    void apply(const cudaStream_t &stream) {
      TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());

      arg.swizzle = tp.aux.x;
      arg.sites_per_block = (arg.threads + tp.grid.x - 1) / tp.grid.x;

      //std::cout << arg;

      if (arg.dagger)
        packKernel<true> <<<tp.grid,tp.block,tp.shared_bytes,stream>>>(arg);
      else
        packKernel<false> <<<tp.grid,tp.block,tp.shared_bytes,stream>>>(arg);
    }

    bool tuneSharedBytes() const { return location & Host ? false : TunableVectorY::tuneSharedBytes(); }

    bool advanceAux(TuneParam &param) const
    {
#ifdef SWIZZLE
      if ( location & Remote ) {  // only swizzling if we're doing remote writing
        if (param.aux.x < (int)maxGridSize()) {
          param.aux.x++;
          return true;
        } else {
          param.aux.x = 1;
          return false;
        }
      } else {
        return false;
      }
#else
      return false;
#endif
    }

    void initTuneParam(TuneParam &param) const {
      TunableVectorY::initTuneParam(param);
      param.aux.x = 1; // swizzle factor
      // if doing a zero-copy policy then ensure that each thread block
      // runs exclusively on a given SM - this is to ensure quality of
      // service for the packing kernel when running concurrently.
      if (location & Host) param.shared_bytes = deviceProp.sharedMemPerBlock / 2 + 1;
    }

    void defaultTuneParam(TuneParam &param) const {
      TunableVectorY::defaultTuneParam(param);
      param.aux.x = 1; // swizzle factor
    }

    TuneKey tuneKey() const { return TuneKey(meta.VolString(), typeid(*this).name(), aux); }

    int tuningIter() const { return 3; }

    long long flops() const { return 2 * ( Arg::spin_project ? Arg::nSpin/2 : Arg::nSpin ) * Arg::nColor * arg.nParity * arg.threads; }

    long long bytes() const {
      size_t precision = sizeof(typename Arg::Float);
      size_t faceBytes = 2 * ( (Arg::spin_project ? Arg::nSpin/2 : Arg::nSpin) + Arg::nSpin ) * Arg::nColor * precision;
      if (precision == QUDA_HALF_PRECISION) faceBytes += 2*sizeof(float); // 2 is from input and output
      return faceBytes * arg.nParity * arg.threads;
    }

  };

  template <typename Float, int nColor, int nSpin>
  void PackGhost(void *ghost[], const ColorSpinorField &field,
                 MemoryLocation location, int nFace,
                 bool dagger, int parity, const cudaStream_t &stream)
  {
    PackArg<Float,nColor,nSpin> arg(ghost, field, nFace, dagger, parity);
    Pack<PackArg<Float,nColor,nSpin>> pack(arg, field, location);
    pack.apply(stream);
  }

  // template on the number of spins
  template <typename Float, int nColor>
  void PackGhost(void *ghost[], const ColorSpinorField &field,
                 MemoryLocation location, int nFace,
                 bool dagger, int parity, const cudaStream_t &stream)
  {
    if (field.Nspin() == 4) {
      PackGhost<Float,nColor,4>(ghost, field, location, nFace, dagger, parity, stream);
    } else {
      errorQuda("Unsupported number of spins %d\n", field.Nspin());
    }
  }

  // template on the number of colors
  template <typename Float>
  void PackGhost(void *ghost[], const ColorSpinorField &field,
                 MemoryLocation location, int nFace,
                 bool dagger, int parity, const cudaStream_t &stream)
  {
    if (field.Ncolor() == 3) {
      PackGhost<Float,3>(ghost, field, location, nFace, dagger, parity, stream);
    } else {
      errorQuda("Unsupported number of colors %d\n", field.Ncolor());
    }
  }

  // Pack the ghost for the Dslash operator
  void PackGhost(void *ghost[2*QUDA_MAX_DIM], const ColorSpinorField &field,
                 MemoryLocation location, int nFace,
                 bool dagger, int parity, const cudaStream_t &stream)
  {
    int nDimPack = 0;
    for (int d=0; d<4; d++) {
      if (!commDim[d]) continue;
      if (d != 3 || getKernelPackT()) nDimPack++;
    }

    if (!nDimPack) return; // if zero then we have nothing to pack

    if (field.Precision() == QUDA_DOUBLE_PRECISION) {
      PackGhost<double>(ghost, field, location, nFace, dagger, parity, stream);
    } else if (field.Precision() == QUDA_SINGLE_PRECISION) {
      PackGhost<float>(ghost, field, location, nFace, dagger, parity, stream);
    } else if (field.Precision() == QUDA_HALF_PRECISION) {
      PackGhost<short>(ghost, field, location, nFace, dagger, parity, stream);
    } else if (field.Precision() == QUDA_QUARTER_PRECISION) {
      PackGhost<char>(ghost, field, location, nFace, dagger, parity, stream);
    } else {
      errorQuda("Unsupported precision %d\n", field.Precision());
    }
  }


} // namespace quda

