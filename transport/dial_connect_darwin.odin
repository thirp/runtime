package transport

import "core:net"
import "core:time"
import "core:sys/posix"

dial_connect_other :: proc(sock: net.TCP_Socket, ep: net.Endpoint, timeout: time.Duration) -> TransportError {
 addr: posix.sockaddr_storage
 switch a in ep.address {
 case net.IP4_Address:
  (^posix.sockaddr_in)(&addr)^ = {sin_len = size_of(posix.sockaddr_in), sin_family = .INET, sin_port = u16be(ep.port), sin_addr = transmute(posix.in_addr)a}
 case net.IP6_Address:
  (^posix.sockaddr_in6)(&addr)^ = {sin6_len = size_of(posix.sockaddr_in6), sin6_family = .INET6, sin6_port = u16be(ep.port), sin6_addr = transmute(posix.in6_addr)a}
 }
 fd := posix.FD(sock)
 if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(addr.ss_len)) == .OK {return .None}
 e := posix.errno()
 if e != .EINPROGRESS && e != .EINTR {return e == .ETIMEDOUT ? .Timeout : .Network}
 deadline := time.time_add(time.now(), timeout)
 for {
  left := time.diff(time.now(), deadline)
  if left <= 0 {return .Timeout}
  pfd := posix.pollfd{fd = fd, events = {.OUT}}
  n := posix.poll(&pfd, 1, max(1, tls_poll_timeout_ms(left)))
  if n < 0 && posix.errno() == .EINTR {continue}
  if n < 0 {return .Network}
  if n == 0 {return .Timeout}
  soerr: i32
  length := posix.socklen_t(size_of(soerr))
  if posix.getsockopt(fd, posix.SOL_SOCKET, posix.Sock_Option(posix.SO_ERROR), &soerr, &length) != .OK {return .Network}
  if soerr == 0 {return .None}
  return posix.Errno(soerr) == .ETIMEDOUT ? .Timeout : .Network
 }
}
