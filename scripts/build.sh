#!/bin/sh -x

root=$(pwd)
PATH_SAV=${PATH}

if test "x${CI_BUILD}" != "x"; then
    if test $(uname -s) = "Linux"; then
        yum update -y
        yum install -y wget flex bison jq readline readline-devel libffi libffi-devel tcl tcl-devel python3-devel zlib-devel cmake glibc-static gmp-devel mpfr-devel patchelf ninja-build
        export PATH=/opt/python/cp312-cp312/bin:$PATH
        if test -z $image; then
            image=manylinux_2_34_x86_64
        fi
        rls_plat="${image}"
    elif test $(uname -s) = "Windows"; then
        rls_plat="windows-x64"
    fi
fi
if test ! -d py; then
    python3 -m venv py
    if test $? -ne 0; then exit 1; fi

    ./py/bin/pip install meson ninja
    if test $? -ne 0; then exit 1; fi
fi

proj=$(pwd)
if test "x${sby_version}" != "x"; then
    rls_version=${sby_version}
else
    rls_version=1.0.0
fi

release_dir="${root}/release/symbiyosys-${rls_version}"
rm -rf ${release_dir}
mkdir -p ${release_dir}

if test ! -d yosys; then
    git clone https://github.com/YosysHQ/yosys
    if test $? -ne 0; then exit 1; fi
    cd ${proj}/yosys
    git submodule update --init
    if test $? -ne 0; then exit 1; fi
    cd ${proj}
fi

cd ${proj}/yosys
make -j$(nproc) PREFIX=${release_dir}
if test $? -ne 0; then exit 1; fi

make install PREFIX=${release_dir}
if test $? -ne 0; then exit 1; fi

cd ${proj}

if test ! -d sby; then
    git clone https://github.com/YosysHQ/sby
fi

cd ${proj}/sby
make install PREFIX=${release_dir}
if test $? -ne 0; then exit 1; fi

cd ${proj}
if test ! -d boolector; then
    git clone https://github.com/boolector/boolector
    if test $? -ne 0; then exit 1; fi
fi

# Create cmake wrapper to inject CMAKE_POLICY_VERSION_MINIMUM=3.5 for all
# cmake invocations (handles old cmake_minimum_required versions like 3.3).
# This must be done before setup-btor2tools.sh, which downloads and builds
# btor2tools (including running cmake) in a single step.
_cmake_real=$(which cmake)
CMAKE_WRAPPER_DIR=$(mktemp -d)
printf '#!/bin/sh\nexec %s -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@"\n' "${_cmake_real}" > ${CMAKE_WRAPPER_DIR}/cmake
chmod +x ${CMAKE_WRAPPER_DIR}/cmake
export PATH=${CMAKE_WRAPPER_DIR}:${PATH}

cd ${proj}/boolector
./contrib/setup-btor2tools.sh
if test $? -ne 0; then exit 1; fi

./contrib/setup-lingeling.sh
if test $? -ne 0; then exit 1; fi

./configure.sh
if test $? -ne 0; then exit 1; fi
make -C build -j$(nproc)
if test $? -ne 0; then exit 1; fi
cp build/bin/boolector ${release_dir}/bin
cp build/bin/btorimc ${release_dir}/bin
cp build/bin/btormbt ${release_dir}/bin
cp build/bin/btormc ${release_dir}/bin
cp build/bin/btoruntrace ${release_dir}/bin
cp deps/btor2tools/build/bin/btorsim ${release_dir}/bin

cd ${proj}

#********************************************************************
#* Build Bitwuzla
#********************************************************************
if test ! -d bitwuzla; then
    git clone https://github.com/bitwuzla/bitwuzla
    if test $? -ne 0; then exit 1; fi
fi

cd ${proj}/bitwuzla
export PATH=${root}/py/bin:${PATH}

./configure.py --shared --wipe --prefix ${release_dir}
if test $? -ne 0; then exit 1; fi

cd build
ninja
if test $? -ne 0; then exit 1; fi

ninja install
if test $? -ne 0; then exit 1; fi

cd ${proj}

# Fix rpath on the bitwuzla binary and its shared libraries so that dependent
# libraries (libgmp, libmpfr, and bitwuzla's own sub-libraries) are found
# relative to the binary's install location at runtime.
# Meson installs libs into a multiarch subdirectory; detect it dynamically.
bwz_libdir=$(find ${release_dir}/lib -name "libbitwuzla.so.0" 2>/dev/null | head -1 | xargs -r dirname)

# Copy libgmp and libmpfr into the release lib directory so the package is
# self-contained on systems where those libraries may differ or be absent.
for lib in libgmp.so libgmp.so.10 libmpfr.so libmpfr.so.6; do
    src=$(ldconfig -p | awk -v l="$lib" '$1 == l { print $NF; exit }')
    if test -f "$src"; then
        cp -L "$src" ${bwz_libdir}/
    fi
done

# bitwuzla binary: libraries live in ../lib/<multiarch> relative to bin/
bwz_librel=$(echo "$bwz_libdir" | sed "s|${release_dir}/||")
patchelf --set-rpath "\$ORIGIN/../${bwz_librel}" ${release_dir}/bin/bitwuzla
if test $? -ne 0; then exit 1; fi

# Each bitwuzla .so: sibling libs are in the same directory
for lib in ${bwz_libdir}/libbitwuzla*.so*; do
    if test -f "$lib" && test ! -L "$lib"; then
        patchelf --set-rpath '$ORIGIN' "$lib"
    fi
done

export PATH=${PATH_SAV}

#********************************************************************
#* Create release tarball
#********************************************************************
cd ${root}/release


tar czf symbiyosys-${rls_plat}-${rls_version}.tar.gz symbiyosys-${rls_version}

