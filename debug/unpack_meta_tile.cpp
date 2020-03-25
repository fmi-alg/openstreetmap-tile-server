#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <string.h>
#include <array>

#define META_MAGIC "META"
#define META_MAGIC_COMPRESSED "METZ"
#define METATILE (8)
    
struct Entry final {
    int offset;
    int size;
};

struct MetaFile final {
    char magic[4];
    int count;
    int x;
    int y;
    int z;
    std::array<Entry, METATILE*METATILE> index;
};

void help() {
    std::cout << "prog <path to metatile>" << std::endl;
}

int main(int argc, char ** argv) {
    if (argc < 2) {
        help();
        return -1;
    }
    std::string path(argv[1]);
    if (path == "-h" || path == "--help") {
        help();
        return -1;
    }
    std::vector<char> data;
    std::fstream file;
    file.open(path, std::ios::in|std::ios::binary);
    if (!file.is_open()) {
        std::cerr << "Could not open file: " << path << std::endl;
        return 1;
    }
    while(!file.eof()) {
        if (!file.good()) {
            std::cerr << "Error occured after reading " << data.size() << " Bytes" << std::endl;
            return 1;
        }
        data.push_back( file.get() );
    }

    std::cout << "Got " << data.size() << " Bytes of data" << std::endl;

    if (data.size() < sizeof(MetaFile)) {
        std::cout << "Not enough data to be a proper meta file" << std::endl;
    }

    MetaFile metaFile;
    ::memcpy(&metaFile, data.data(), sizeof(MetaFile));

    std::cout << "Read " << sizeof(MetaFile) << " header bytes" << std::endl;
    std::cout << "MetaFile {\n"
                << "  magic = " << metaFile.magic[0] << metaFile.magic[1] << metaFile.magic[2] << metaFile.magic[3] << '\n'
                << "  count = " << metaFile.count << '\n'
                << "  x = " << metaFile.x << '\n'
                << "  y = " << metaFile.y << '\n'
                << "  z = " << metaFile.z << '\n'
                << "  index = {\n";
    for(std::size_t i(0); i < METATILE*METATILE; ++i) {
        std::cout << "    [" << i << "] = { .offset = " << metaFile.index[i].offset << ", .size = " << metaFile.index[i].size << "}\n";
    }
    std::cout << "  }\n}\n" << std::endl;

    std::cout << "Writing files..." << std::endl;
    for(int i(0); i < metaFile.count; ++i) {
        std::fstream outfile;
        std::string outFileName = path + "." + std::to_string(i) + ".png";
        int offset = metaFile.index[i].offset;
        int size = metaFile.index[i].size;

        outfile.open(outFileName, std::ios::out|std::ios::binary);
        if (!outfile.is_open()) {
            std::cerr << "Could not open file " << outFileName << " for writing" << std::endl;
            return -1;
        }
        outfile.write(data.data()+offset, size);
        if (!outfile.good()) {
            std::cerr << "Error occured during write to " << outFileName << std::endl;
            return -1;
        }
        outfile.flush();
        outfile.close();
    }
    return 0;
}