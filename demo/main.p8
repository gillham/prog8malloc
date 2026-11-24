%import libmem
%import tests
%zeropage dontuse

main {
    sub start() {
        txt.lowercase()
        tests.run_all()
    }
}
