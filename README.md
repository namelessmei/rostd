# rostd

A high-performance, low-level standard library for Roblox game development, designed with C++-like principles of performance and developer freedom.

## Modules

### Container

- [X] Ring Buffer
  - Efficient, fixed-size circular data structure
  - Minimal allocation overhead
  - Direct memory management

### Manager

- [X] InputManager
  - Advanced input tracking
  - Flexible input sequence recognition
  - Minimal runtime overhead

### Monads

- [X] Result
  - Explicit error handling
  - No silent failures
  - Rust-inspired error management

### Serdes

- [X] Protobuf
  - Efficient binary serialization
  - Low-overhead data encoding/decoding

### Utils

- [X] Signal
  - High-performance event handling
  - Minimal allocation
  - Efficient callback management

## Design Principles

- Performance first
- Explicit over implicit
- Minimal abstraction penalty
- Developer freedom
- No unnecessary guardrails