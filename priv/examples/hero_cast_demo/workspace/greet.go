package greet

// Greet returns a greeting for name.
func Greet(name string) string {
	// BUG (t0): the wrong word — the test asserts "Hello, …".
	return "Goodbye, " + name + "!"
}
