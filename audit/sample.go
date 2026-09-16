package main

import (
	"os"
	"path/filepath"
)

func writeSample() error {
	if err := os.MkdirAll(sampleDir, 0o755); err != nil {
		return err
	}
	files := map[string]string{
		"go.mod": `module example.com/aiwritten
go 1.21

require (
	github.com/google/uuid v1.6.0
	github.com/pkg/errors v0.9.1
)
`,
		"main.go": `package main

import (
	"fmt"
	"os" // imported but never used
	"github.com/google/uuid"
)

func main() {
	id := uuid.New()
	fmt.Println("order id:", id)

	order := buildOrder()
	fmt.Println("order:", order)

	total1 := applyDiscount(100.0, 0.1)
	total2 := applyTax(200.0, 0.2)
	fmt.Println("totals:", total1, total2)
}
`,
		"service.go": `package main

import (
	"fmt"
	"strings"
)

// buildOrder returns a fake order. Contains a shadowed variable.
func buildOrder() string {
	name := "widget"
	if len(name) > 0 {
		name := strings.ToUpper(name) // shadows the outer name
		fmt.Println("inner:", name)
	}
	return name
}

// applyDiscount applies a discount.
func applyDiscount(price, rate float64) float64 {
	if rate < 0 {
		rate = 0
	}
	if rate > 1 {
		rate = 1
	}
	return price * (1 - rate)
}

// applyTax applies tax. Duplicated logic vs applyDiscount.
func applyTax(price, rate float64) float64 {
	if rate < 0 {
		rate = 0
	}
	if rate > 1 {
		rate = 1
	}
	return price * (1 + rate)
}

// deadCode is never called anywhere.
func deadCode() string {
	return "nobody calls me"
}
`,
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(sampleDir, name), []byte(content), 0o644); err != nil {
			return err
		}
	}
	return nil
}
