package authz

test_get_allowed if {
	allow with input as {"method": "GET"}
}

test_post_denied if {
	not allow with input as {"method": "POST"}
}
