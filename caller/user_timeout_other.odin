#+build !linux
package caller

import trans "../transport"

caller_set_user_timeout :: proc(conn: ^trans.Connection) {}
