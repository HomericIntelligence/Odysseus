from conan import ConanFile
from conan.tools.cmake import CMakeToolchain, CMakeDeps


class ValidateInstallConan(ConanFile):
    """Minimal consumer project that validates C++ packages install correctly."""

    name = "validate-install"
    version = "0.0.1"
    settings = "os", "compiler", "build_type", "arch"

    def requirements(self):
        self.requires("projectagamemnon/0.1.0")
        self.requires("projectnestor/0.1.0")
        self.requires("projectkeystone/0.1.0")

    def generate(self):
        CMakeDeps(self).generate()
        CMakeToolchain(self).generate()
