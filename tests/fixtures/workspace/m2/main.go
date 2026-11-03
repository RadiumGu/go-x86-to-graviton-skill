// A module in the tree that go.work does not list: inside the workspace the go command
// refuses it, so the scanner must resolve it standalone (GOWORK=off) and say so.
package main

func main() {}
