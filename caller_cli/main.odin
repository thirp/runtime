package main

import connect "connect"
import "core:os"

main :: proc() {
	os.exit(connect.connect_main(os.args[1:]))
}
