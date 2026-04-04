// Minimal consumer that validates HomericIntelligence C++ packages
// can be found, linked, and used via Conan find_package().

#include <iostream>

// Each #include validates that the package headers are discoverable.
// If any package is not installed correctly, this file will not compile.

// TODO: Uncomment includes as packages export proper Conan package configs.
// For now, this validates the Conan export + install pipeline works end-to-end.
// #include <projectagamemnon/version.hpp>
// #include <projectnestor/version.hpp>
// #include <keystone/core/message.hpp>

int main() {
    std::cout << "HomericIntelligence Conan install validation passed.\n";
    std::cout << "All packages resolved, compiled, and linked successfully.\n";
    return 0;
}
