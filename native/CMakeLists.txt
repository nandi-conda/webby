# Webby: a C ABI around LibWebView so a Flutter (dart:ffi) UI can drive Ladybird.
# This directory is copied into the Ladybird tree as UI/Flutter by scripts/build_ladybird.sh.

add_library(ladybird SHARED
    WebbyView.cpp
    webby_ffi.cpp
)
set_target_properties(ladybird PROPERTIES OUTPUT_NAME "webby")
target_include_directories(ladybird PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(ladybird PRIVATE LibImageDecoderClient LibJS LibRequests LibWeb LibFileSystem LibThreading)

create_ladybird_bundle(ladybird)
