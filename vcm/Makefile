OUTPUT = .
OBJ = obj

# Source files
SOURCES = main.cpp ipc.cpp tcpServer.cpp util.cpp

# Libraries to link (headers only)
LIBS = json-c hiredis

# Flags from pkg-config
CFLAGS += -Wall -pthread
CFLAGS += $(shell pkg-config --cflags $(LIBS))

# Remove _FILE_OFFSET_BITS=64 to avoid GLIBC_2.33 stat64 dependency
# Use 32-bit file offsets for compatibility with target GLIBC 2.31
CFLAGS := $(filter-out -D_FILE_OFFSET_BITS=64,$(CFLAGS))

# Static linking for json-c and hiredis to avoid runtime dependency
LDFLAGS += -l:libjson-c.a -l:libhiredis.a
LDFLAGS += -lpthread

# Object files
OBJS = $(patsubst %.cpp,$(OBJ)/%.o,$(SOURCES))

# Target
TARGET = vcm

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) -o $@ $^ $(LDFLAGS)

$(OBJ)/%.o: %.cpp | $(OBJ)
	$(CXX) $(CFLAGS) -c $< -o $@

$(OBJ):
	mkdir -p $(OBJ)

clean:
	rm -rf $(OBJ) $(TARGET)

.PHONY: all clean
