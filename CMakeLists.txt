cmake_minimum_required(VERSION 3.5)
project(numaann)

#OpenMP
find_package(OpenMP)
if (OPENMP_FOUND)
    set (CMAKE_C_FLAGS "${CMAKE_C_FLAGS} ${OpenMP_C_FLAGS}")
    set (CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${OpenMP_CXX_FLAGS}")
else()
    message(FATAL_ERROR "no OpenMP supprot")
endif()

#Boost::json
find_package(Boost 1.85 REQUIRED COMPONENTS json)
if(Boost_FOUND)
    message(STATUS "Boost_INCLUDE_DIRS: ${Boost_INCLUDE_DIRS}")
    message(STATUS "Boost_LIBRARY_DIRS: ${Boost_LIBRARY_DIRS}")
    message(STATUS "Boost_LIBRARIES: ${Boost_LIBRARIES}")
    include_directories(${Boost_INCLUDE_DIRS})
    link_libraries(${Boost_LIBRARIES})
else()
    message(FATAL_ERROR "Could not find Boost libraries")
endif()

#MKL Config
if (MSVC)
    # Only the DiskANN DLL and one of the tools need MKL libraries. Additionally, only a small part of MKL is used.
    # Given that and given that MKL DLLs are huge, use static linking to end up with no MKL DLL dependencies and with
    # significantly smaller disk footprint.
    #
    # The compile options are not modified as there's already an unconditional -DMKL_ILP64 define below
    # for all architectures, which is all that's needed.
    set(DISKANN_MKL_INCLUDE_DIRECTORIES "${DISKANN_MSVC_PACKAGES}/intelmkl.static.win-x64/lib/native/include")
    set(DISKANN_MKL_LIB_PATH "${DISKANN_MSVC_PACKAGES}/intelmkl.static.win-x64/lib/native/win-x64")

    set(DISKANN_MKL_LINK_LIBRARIES
        "${DISKANN_MKL_LIB_PATH}/mkl_intel_ilp64.lib"
        "${DISKANN_MKL_LIB_PATH}/mkl_core.lib"
        "${DISKANN_MKL_LIB_PATH}/mkl_intel_thread.lib")
else()
    # expected path for manual intel mkl installs
    if (DEFINED OMP_PATH)
        if (IS_DIRECTORY ${OMP_PATH})
            set(_OMP_PATH ${OMP_PATH})
        else()
            get_filename_component(_OMP_PATH ${OMP_PATH} DIRECTORY)
        endif()
    else()
        set(_OMP_PATH "")
    endif()

    if (NOT DEFINED OPENMP_LINK_LIB OR "${OPENMP_LINK_LIB}" STREQUAL "")
        if (DEFINED _OMP_PATH AND EXISTS "${_OMP_PATH}/libiomp5.so")
            set(OPENMP_LINK_LIB iomp5)
        elseif(DEFINED _OMP_PATH AND EXISTS "${_OMP_PATH}/libgomp.so")
            set(OPENMP_LINK_LIB gomp)
        else()
            find_library(INTEL_OMP_LIB iomp5 PATHS /opt/intel/oneapi/compiler/latest/linux/compiler/lib/intel64_lin /usr/lib/x86_64-linux-gnu /opt/intel/lib/intel64_lin)
            if (INTEL_OMP_LIB)
                set(OPENMP_LINK_LIB iomp5)
                get_filename_component(_OMP_PATH ${INTEL_OMP_LIB} DIRECTORY)
            else()
                find_library(GNU_OMP_LIB gomp PATHS /usr/lib/x86_64-linux-gnu /usr/lib /usr/local/lib /usr/local/lib64 /lib/x86_64-linux-gnu)
                if (GNU_OMP_LIB)
                    set(OPENMP_LINK_LIB gomp)
                    get_filename_component(_OMP_PATH ${GNU_OMP_LIB} DIRECTORY)
                else()
                    set(OPENMP_LINK_LIB "")
                    message(WARNING "Could not detect libiomp5 or libgomp on disk. Linker will use OpenMP flags from compiler options only (-fopenmp).")
                endif()
            endif()
        endif()
    else()
        message(STATUS "Using user-specified OPENMP_LINK_LIB=${OPENMP_LINK_LIB}")
    endif()

    if (DEFINED _OMP_PATH AND _OMP_PATH STREQUAL "")
    else()
        link_directories(${_OMP_PATH})
    endif()

    set(POSSIBLE_MKL_LIB_PATHS "/opt/intel/oneapi/mkl/latest/lib/intel64/libmkl_core.so;/usr/lib/x86_64-linux-gnu/libmkl_core.so;/opt/intel/mkl/lib/intel64/libmkl_core.so")
    foreach(POSSIBLE_MKL_LIB_PATH ${POSSIBLE_MKL_LIB_PATHS})
        if (EXISTS ${POSSIBLE_MKL_LIB_PATH})
            get_filename_component(MKL_PATH ${POSSIBLE_MKL_LIB_PATH} DIRECTORY)
        endif()
    endforeach()

    set(POSSIBLE_MKL_INCLUDE_PATHS "/opt/intel/oneapi/mkl/latest/include;/usr/include/mkl;/opt/intel/mkl/include/;")
    foreach(POSSIBLE_MKL_INCLUDE_PATH ${POSSIBLE_MKL_INCLUDE_PATHS})
        if (EXISTS ${POSSIBLE_MKL_INCLUDE_PATH})
            set(MKL_INCLUDE_PATH ${POSSIBLE_MKL_INCLUDE_PATH})
        endif()
    endforeach()
    if(NOT MKL_PATH)
        message(FATAL_ERROR "Could not find Intel MKL in standard locations; use -DMKL_PATH to specify the install location for your environment")
    elseif(NOT MKL_INCLUDE_PATH)
        message(FATAL_ERROR "Could not find Intel MKL in standard locations; use -DMKL_INCLUDE_PATH to specify the install location for headers for your environment")
    endif()
    if (EXISTS ${MKL_PATH}/libmkl_def.so.2)
        set(MKL_DEF_SO ${MKL_PATH}/libmkl_def.so.2)
    elseif(EXISTS ${MKL_PATH}/libmkl_def.so)
        set(MKL_DEF_SO ${MKL_PATH}/libmkl_def.so)
    else()
        message(FATAL_ERROR "Despite finding MKL, libmkl_def.so was not found in expected locations.")
    endif()
    link_directories(${MKL_PATH})
    include_directories(${MKL_INCLUDE_PATH})

    # compile flags and link libraries
    add_compile_options(-m64 -Wl,--no-as-needed)
    if (NOT DEFINED OPENMP_LINK_LIB OR "${OPENMP_LINK_LIB}" STREQUAL "")
        set(OPENMP_LINK_LIB gomp)
    endif()

    if (NOT DEFINED MKL_THREADING_LIB OR "${MKL_THREADING_LIB}" STREQUAL "")
        if (OPENMP_LINK_LIB STREQUAL "iomp5")
            set(_CANDIDATES mkl_intel_thread mkl_gnu_thread mkl_intel_sequential)
        else()
            # GNU OpenMP runtime -> use GNU-threaded MKL variant when available.
            set(_CANDIDATES mkl_gnu_thread mkl_intel_thread mkl_intel_sequential)
        endif()

        foreach(_th ${_CANDIDATES})
            find_library(_MKL_THREAD_LIB_FOUND ${_th} PATHS ${MKL_PATH} NO_DEFAULT_PATH)
            if (_MKL_THREAD_LIB_FOUND)
                set(MKL_THREADING_LIB ${_th})
                break()
            endif()
        endforeach()
        if (NOT MKL_THREADING_LIB)
            message(FATAL_ERROR "Could not find a usable MKL threading lib in ${MKL_PATH}. Set -DMKL_THREADING_LIB manually.")
        endif()
    endif()

    if (OPENMP_LINK_LIB STREQUAL "gomp" AND NOT MKL_THREADING_LIB STREQUAL "mkl_intel_sequential")
        message(WARNING "OPENMP_LINK_LIB=gomp but MKL_THREADING_LIB=${MKL_THREADING_LIB}; this often causes undefined __kmpc_* symbols. "
                        "For GNU OpenMP, prefer -DMKL_THREADING_LIB=mkl_intel_sequential")
    endif()

    message(STATUS "Using OpenMP link lib: ${OPENMP_LINK_LIB}")
    message(STATUS "Using MKL threading lib: ${MKL_THREADING_LIB}")

    if (NOT PYBIND)
        link_libraries(mkl_intel_ilp64 ${MKL_THREADING_LIB} mkl_core ${OPENMP_LINK_LIB} pthread m dl)
    else()
        # static linking for python so as to minimize customer dependency issues
        link_libraries(
                ${MKL_PATH}/libmkl_intel_ilp64.a
                ${MKL_PATH}/${MKL_THREADING_LIB}.a
                ${MKL_PATH}/libmkl_core.a
                ${MKL_DEF_SO}
                ${OPENMP_LINK_LIB}
                pthread
                m
                dl
        )
    endif()
endif()

add_definitions(-DMKL_ILP64)

set(CMAKE_CXX_STANDARD 17)

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -g -DDEBUG -Wextra -march=native")
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -DNDEBUG -march=native")

## SET the paths for MPI C/CXX compiler
# set(CMAKE_CXX_COMPILER "/PATH/OF/MPI/bin/mpic++")
set(CMAKE_CXX_COMPILER mpic++)

## Set include paths
include_directories(${PROJECT_SOURCE_DIR}/core)
include_directories(${PROJECT_SOURCE_DIR}/rdma_lib)
include_directories(${PROJECT_SOURCE_DIR}/utils)
include_directories(${PROJECT_SOURCE_DIR}/include/)
add_subdirectory(src)
add_subdirectory(tests)
# add_subdirectory(app)
