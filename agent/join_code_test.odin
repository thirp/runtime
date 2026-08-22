package agent

import proto "../protocol"
import trans "../transport"
import "core:testing"

join_code_char_ok :: proc(c: u8) -> bool {
	alphabet := JOIN_CODE_ALPHABET
	for i in 0 ..< len(alphabet) {
		if alphabet[i] == c {
			return true
		}
	}
	return false
}

@(test)
test_generate_join_code_length_and_alphabet :: proc(t: ^testing.T) {
	seen: map[string]struct{}
	defer {
		for k in seen {
			delete(k)
		}
		delete(seen)
	}
	for _ in 0 ..< 32 {
		code, err := generate_join_code()
		testing.expect_value(t, err, AgentError.None)
		testing.expect_value(t, len(code), JOIN_CODE_LEN)
		for i in 0 ..< len(code) {
			testing.expect(t, join_code_char_ok(code[i]))
		}
		if _, exists := seen[code]; !exists {
			seen[code] = {}
		} else {
			delete(code)
		}
	}
	testing.expect(t, len(seen) > 1)
}

@(test)
test_host_ephemeral_produces_valid_service_id :: proc(t: ^testing.T) {
	agent: Agent
	err := agent_init(
		&agent,
		AgentConfig {
			broker   = trans.loopback_endpoint(1),
			token    = "host-dev-token",
			insecure = true,
		},
	)
	testing.expect_value(t, err, AgentError.None)
	defer agent_destroy(&agent)

	hosting, herr := host_ephemeral(
		&agent,
		EphemeralConfig{namespace = "game", local_address = trans.loopback_endpoint(9)},
	)
	testing.expect_value(t, herr, AgentError.None)
	defer hosting_destroy(&hosting)
	testing.expect_value(t, len(hosting.join_code), JOIN_CODE_LEN)
	sid_err := proto.check_service_id(string(hosting.service_id))
	testing.expect_value(t, sid_err, proto.ServiceIdError.None)
	got := string(hosting.service_id)
	testing.expect(t, len(got) == 5 + len(hosting.join_code))
	testing.expect(t, got[:5] == "game/")
	testing.expect(t, got[5:] == hosting.join_code)
}
