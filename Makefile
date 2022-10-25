CXX = clang++
CC = clang
LD = lld
SGX_SDK ?= $(abspath ../../SGXSan/install)
#SGX_SDK ?= /path/to/the/sgxsdk
SGX_MODE ?= SIM
SGX_ARCH ?= x64
SGX_DEBUG ?= 1

ifeq ($(SGX_SDK),/path/to/the/sgxsdk)
    $(error "SGX_SDK is not set ")
endif

ifeq ($(SGX_ARCH), x86)
	SGX_COMMON_CFLAGS := -m32
	SGX_LIBRARY_PATH := $(SGX_SDK)/lib
	SGX_ENCLAVE_SIGNER := $(SGX_SDK)/bin/x86/sgx_sign
	SGX_EDGER8R := $(SGX_SDK)/bin/x86/sgx_edger8r
else
	SGX_COMMON_CFLAGS := -m64
	SGX_LIBRARY_PATH := $(SGX_SDK)/lib64
	SGX_ENCLAVE_SIGNER := $(SGX_SDK)/bin/x64/sgx_sign
	SGX_EDGER8R := $(SGX_SDK)/bin/x64/sgx_edger8r
endif

ifeq ($(SGX_DEBUG), 1)
ifeq ($(SGX_PRERELEASE), 1)
$(error Cannot set SGX_DEBUG and SGX_PRERELEASE at the same time!!)
endif
endif

ifeq ($(SGX_DEBUG), 1)
		SGX_COMMON_CFLAGS += -O0 -g
else
		SGX_COMMON_CFLAGS += -O2
endif

######## App Settings ########

ifneq ($(SGX_MODE), HW)
	Urts_Library_Name := sgx_urts_sim
else
	Urts_Library_Name := sgx_urts
endif

App_Cpp_Files := App/App.cpp App/sgx_utils/sgx_utils.cpp
App_Include_Paths := -IApp -I$(SGX_SDK)/include

App_C_Flags := $(SGX_COMMON_CFLAGS) $(App_Include_Paths) \
	-flegacy-pass-manager \
	-Xclang -load -Xclang $(SGX_SDK)/lib64/libSGXFuzzerPass.so \
	-mllvm -edl-json=Enclave/Enclave.edl.json \
	-fsanitize-coverage=inline-8bit-counters

# Three configuration modes - Debug, prerelease, release
#   Debug - Macro DEBUG enabled.
#   Prerelease - Macro NDEBUG and EDEBUG enabled.
#   Release - Macro NDEBUG enabled.
ifeq ($(SGX_DEBUG), 1)
		App_C_Flags += -DDEBUG -UNDEBUG -UEDEBUG
else ifeq ($(SGX_PRERELEASE), 1)
		App_C_Flags += -DNDEBUG -DEDEBUG -UDEBUG
else
		App_C_Flags += -DNDEBUG -UEDEBUG -UDEBUG
endif

App_Cpp_Flags := $(App_C_Flags) -std=c++11
App_Link_Flags := $(SGX_COMMON_CFLAGS) -L$(SGX_LIBRARY_PATH) -l$(Urts_Library_Name) -lpthread \
	-lrdmacm -libverbs \
	-ldl \
	-Wl,-rpath=$(shell pwd) \
	-Wl,-rpath=/opt/intel/sgxsdk/lib64 \
	-lSGXFuzzerRT \
	-fsanitize=fuzzer \
	-lcrypto -lboost_program_options

ifneq ($(SGX_MODE), HW)
	App_Link_Flags += -lsgx_uae_service_sim
else
	App_Link_Flags += -lsgx_uae_service
endif

App_Cpp_Objects := $(App_Cpp_Files:.cpp=.o)

App_Name := app

######## Enclave Settings ########

ifneq ($(SGX_MODE), HW)
	Trts_Library_Name := sgx_trts_sim
	Service_Library_Name := sgx_tservice_sim
else
	Trts_Library_Name := sgx_trts
	Service_Library_Name := sgx_tservice
endif
Crypto_Library_Name := sgx_tcrypto

Enclave_C_Files := $(wildcard Enclave/sqlite/*.c) Enclave/vmem.c Enclave/xxhash.c Enclave/synthetic.c \
		    Enclave/sgxvfs.c Enclave/speedtest1.c Enclave/server.c Enclave/os-sgx.c

Enclave_Include_Paths := -IEnclave -I$(SGX_SDK)/include -I$(SGX_SDK)/include/tlibc -I$(SGX_SDK)/include/stlport

#SQLITE_FLAGS :=  -DSQLITE_THREADSAFE=0  -DSQLITE_ENABLE_MEMSYS5 -DSQLITE_OMIT_WAL  -DSQLITE_PCACHE_SEPARATE_HEADER -DWITH_IPP
SQLITE_FLAGS :=  -DSQLITE_THREADSAFE=0 -DSQLITE_ENABLE_MEMSYS5 -DSQLITE_PCACHE_SEPARATE_HEADER

Enclave_C_Flags := $(SGX_COMMON_CFLAGS) $(SQLITE_FLAGS) -fvisibility=hidden -fpie -fstack-protector $(Enclave_Include_Paths) \
	-flto -fno-discard-value-names \
	-fsanitize-coverage=inline-8bit-counters

Enclave_Cpp_Flags := $(Enclave_C_Flags)

Enclave_Link_Flags := $(SGX_COMMON_CFLAGS) -L$(SGX_LIBRARY_PATH) \
	-nostdlib -nodefaultlibs -nostartfiles  \
	-Wl,--whole-archive -lSGXSanRT -l$(Trts_Library_Name) -Wl,--no-whole-archive \
	-Wl,--start-group -lsgx_tsafecrt -l$(Crypto_Library_Name) -l$(Service_Library_Name) -Wl,--end-group \
	-Wl,-Bstatic -Wl,-Bsymbolic \
	-Wl,-eenclave_entry -Wl,--export-dynamic  \
	-Wl,--defsym,__ImageBase=0 \
	-Wl,--version-script=Enclave/Enclave.lds \
	-fuse-ld=$(LD) \
	-Wl,-save-temps \
	-Wl,--lto-legacy-pass-manager \
	-Wl,-mllvm=-load=$(SGX_SDK)/lib64/libSGXSanPass.so \
	-Wl,-mllvm=-edl-json=Enclave/Enclave.edl.json \
	-Wl,-mllvm=-enable-slsan=false \
	-Wl,-mllvm=--stat=false \
	--shared

Enclave_C_Objects := $(Enclave_C_Files:.c=.o)

Enclave_Name := enclave.so
Signed_Enclave_Name := enclave.signed.so
Enclave_Config_File := Enclave/Enclave.config.xml

ifeq ($(SGX_MODE), HW)
ifneq ($(SGX_DEBUG), 1)
ifneq ($(SGX_PRERELEASE), 1)
Build_Mode = HW_RELEASE
endif
endif
endif


.PHONY: all run

ifeq ($(Build_Mode), HW_RELEASE)
all: $(App_Name) $(Enclave_Name)
	@echo "The project has been built in release hardware mode."
	@echo "Please sign the $(Enclave_Name) first with your signing key before you run the $(App_Name) to launch and access the enclave."
	@echo "To sign the enclave use the command:"
	@echo "   $(SGX_ENCLAVE_SIGNER) sign -key <your key> -enclave $(Enclave_Name) -out <$(Signed_Enclave_Name)> -config $(Enclave_Config_File)"
	@echo "You can also sign the enclave using an external signing tool. See User's Guide for more details."
	@echo "To build the project in simulation mode set SGX_MODE=SIM. To build the project in prerelease mode set SGX_PRERELEASE=1 and SGX_MODE=HW."
else
all: $(App_Name) $(Signed_Enclave_Name)
endif

run: all
ifneq ($(Build_Mode), HW_RELEASE)
	@$(CURDIR)/$(App_Name)
	@echo "RUN  =>  $(App_Name) [$(SGX_MODE)|$(SGX_ARCH), OK]"
endif

######## App Objects ########

App/Enclave_u.h: Enclave/Enclave.edl
	@cd App && $(SGX_EDGER8R) --untrusted ../Enclave/Enclave.edl --search-path ../Enclave --search-path $(SGX_SDK)/include
	@echo "GEN  =>  $@"

App/Enclave_u.c: App/Enclave_u.h

App/Enclave_u.o: App/Enclave_u.c Enclave/Enclave.edl.json
	@$(CC) $(App_C_Flags) -c $< -o $@
	@echo "CC   <=  $<"

App/%.o: App/%.cpp
	@$(CXX) $(App_Cpp_Flags) -c $< -o $@
	@echo "CXX  <=  $<"

$(App_Name): App/Enclave_u.o enclave.so
	@$(CXX) $^ -o $@ $(App_Link_Flags)
	@echo "LINK =>  $@"


######## Enclave Objects ########

Enclave/Enclave.edl.json: Enclave/Enclave_t.h

Enclave/Enclave_t.h: Enclave/Enclave.edl
	@cd Enclave && $(SGX_EDGER8R) --trusted ../Enclave/Enclave.edl --search-path ../Enclave --search-path $(SGX_SDK)/include
	@echo "GEN  =>  $@"

Enclave/Enclave_t.c: Enclave/Enclave_t.h

Enclave/Enclave_t.o: Enclave/Enclave_t.c
	@$(CC) $(Enclave_C_Flags) -c $< -o $@
	@echo "CC   <=  $<"

Enclave/%.o: Enclave/%.c
	$(CC) $(Enclave_C_Flags) -c  $< -o $@
	@echo "CC  <=  $<"

$(Enclave_Name): Enclave/Enclave_t.o $(Enclave_C_Objects) Enclave/Enclave.edl.json
	$(CC) $(filter-out Enclave/Enclave.edl.json,$^) -o $@ $(Enclave_Link_Flags)
	@echo "LINK =>  $@"

$(Signed_Enclave_Name): $(Enclave_Name)
# @$(SGX_ENCLAVE_SIGNER) sign -key Enclave/Enclave_private.pem -enclave $(Enclave_Name) -out $@ -config $(Enclave_Config_File)
	@echo "SIGN =>  $@"

.PHONY: clean

clean:
	@rm -f $(App_Name) $(Enclave_Name) $(Signed_Enclave_Name) $(App_Cpp_Objects) App/Enclave_u.* $(Enclave_C_Objects)  Enclave/Enclave_t.* Enclave/Enclave.edl.json *.bc enclave.so.lto.o enclave.so.resolution.txt
