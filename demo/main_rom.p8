%launcher none
%option romable
%import libmem
%import tests_rom
%zeropage dontuse

main {
    sub start() {
        txt.lowercase()
        tests.run_all()
    }
}
