// The hooks Ladybird's C++ (AK) gives its Rust crates, for running a Rust crate's tests and tools as wasm32-wasip1
// commands without AK: Rust's own panic message is printed and the command aborts.
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

void ladybird_set_rust_symbol_demangler(void* demangler) { (void)demangler; }
void ladybird_rust_panic(uint8_t const* message, size_t message_length, uint8_t const* filename, size_t filename_length,
    uint32_t line, uint32_t column, bool (*is_panicking)(void))
{
    (void)message, (void)message_length, (void)filename, (void)filename_length, (void)line, (void)column,
        (void)is_panicking;
}
void ladybird_rust_panic_hook_returned(void) { }
void ladybird_rust_panic_may_abort(void) { }
void ladybird_rust_panic_will_abort(void) { }
