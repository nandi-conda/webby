# Webby: a C ABI around LibWebView so webby's Nim UI can drive Ladybird.
# This directory is copied into the Ladybird tree as UI/Flutter (a name kept from the first front end) by scripts/build_ladybird.sh.

find_package(OpenSSL REQUIRED)

add_library(ladybird SHARED
    Authenticator.cpp
    WebbyGeolocation.cpp
    WebbyView.cpp
    webby_ffi.cpp
)
target_include_directories(ladybird PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(ladybird PRIVATE LibImageDecoderClient LibJS LibRequests LibWeb LibFileSystem LibThreading OpenSSL::Crypto)

create_ladybird_bundle(ladybird)
# After the bundle helper, which names the target "Ladybird".
set_target_properties(ladybird PROPERTIES OUTPUT_NAME "webby")
