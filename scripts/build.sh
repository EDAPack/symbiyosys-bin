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

        # Yosys requires bison >= 3.6; manylinux_2_28 only ships 3.0.4.
        # Build a newer bison from source if needed.
        bison_ver=$(bison --version | head -1 | sed 's/[^0-9.]//g')
        bison_major=$(echo "$bison_ver" | cut -d. -f1)
        bison_minor=$(echo "$bison_ver" | cut -d. -f2)
        if test "$bison_major" -lt 3 || { test "$bison_major" -eq 3 && test "$bison_minor" -lt 6; }; then
            echo "bison $bison_ver too old, building bison 3.8.2 from source"
            wget -q https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.gz
            tar xzf bison-3.8.2.tar.gz
            cd bison-3.8.2
            ./configure --prefix=/usr/local
            if test $? -ne 0; then exit 1; fi
            make -j$(nproc) install
            if test $? -ne 0; then exit 1; fi
            cd ${root}
        fi

        # Bitwuzla requires GMP >= 6.3; manylinux images ship 6.2.x.
        # Build GMP 6.3.0 from source if needed.
        gmp_ver=$(pkg-config --modversion gmp 2>/dev/null || echo "0.0.0")
        gmp_major=$(echo "$gmp_ver" | cut -d. -f1)
        gmp_minor=$(echo "$gmp_ver" | cut -d. -f2)
        if test "$gmp_major" -lt 6 || { test "$gmp_major" -eq 6 && test "$gmp_minor" -lt 3; }; then
            echo "GMP $gmp_ver too old, building GMP 6.3.0 from source"
            wget -q https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz
            tar xJf gmp-6.3.0.tar.xz
            cd gmp-6.3.0
            ./configure --prefix=/usr/local --enable-shared --enable-static
            if test $? -ne 0; then exit 1; fi
            make -j$(nproc) install
            if test $? -ne 0; then exit 1; fi
            ldconfig
            cd ${root}
        fi

        # Bitwuzla requires MPFR >= 4.2.1; manylinux images ship 4.1.x.
        # Build MPFR 4.2.1 from source if needed (depends on GMP, built above).
        mpfr_ver=$(pkg-config --modversion mpfr 2>/dev/null || echo "0.0.0")
        mpfr_major=$(echo "$mpfr_ver" | cut -d. -f1)
        mpfr_minor=$(echo "$mpfr_ver" | cut -d. -f2)
        mpfr_patch=$(echo "$mpfr_ver" | cut -d. -f3)
        if test "$mpfr_major" -lt 4 || { test "$mpfr_major" -eq 4 && test "$mpfr_minor" -lt 2; } || { test "$mpfr_major" -eq 4 && test "$mpfr_minor" -eq 2 && test "${mpfr_patch:-0}" -lt 1; }; then
            echo "MPFR $mpfr_ver too old, building MPFR 4.2.1 from source"
            wget -q https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.1.tar.xz
            tar xJf mpfr-4.2.1.tar.xz
            cd mpfr-4.2.1
            ./configure --prefix=/usr/local --with-gmp=/usr/local --enable-shared --enable-static
            if test $? -ne 0; then exit 1; fi
            make -j$(nproc) install
            if test $? -ne 0; then exit 1; fi
            ldconfig
            cd ${root}
        fi
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
cp ${proj}/scripts/export.envrc ${release_dir}/
cd ${root}/release


tar czf symbiyosys-${rls_plat}-${rls_version}.tar.gz symbiyosys-${rls_version}

