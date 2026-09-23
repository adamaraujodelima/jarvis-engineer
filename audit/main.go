package main

import (
	"bytes"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

var sampleDir = "./sample"

func main() {
	fmt.Println("==============================================")
	fmt.Println("  AUDITING AN AI-WRITTEN CODEBASE: FIELD GUIDE")
	fmt.Println("==============================================")
	fmt.Println()

	if err := writeSample(); err != nil {
		fmt.Println("ERROR generating sample:", err)
		os.Exit(1)
	}
	fmt.Println("[setup] sample AI-written codebase written to ./sample")
	fmt.Println()

	auditUnusedDeps()
	auditUnusedImports()
	auditShadowing()
	auditDuplication()
	auditDeadCode()

	fmt.Println("==============================================")
	fmt.Println("  AUDIT COMPLETE — see findings above")
	fmt.Println("==============================================")
}

func parseFiles(fset *token.FileSet) []*ast.File {
	var files []*ast.File
	entries, err := os.ReadDir(sampleDir)
	if err != nil {
		return files
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".go") {
			continue
		}
		f, err := parser.ParseFile(fset, filepath.Join(sampleDir, e.Name()), nil, 0)
		if err != nil {
			fmt.Println("  parse error:", err)
			continue
		}
		files = append(files, f)
	}
	return files
}

func importName(imp *ast.ImportSpec) string {
	if imp.Name != nil {
		return imp.Name.Name
	}
	path := strings.Trim(imp.Path.Value, "\"")
	parts := strings.Split(path, "/")
	return parts[len(parts)-1]
}

func isExported(name string) bool {
	return name != "" && name[0] >= 'A' && name[0] <= 'Z'
}

func auditUnusedDeps() {
	fmt.Println("--- [1] UNUSED DEPENDENCIES ---")
	data, err := os.ReadFile(filepath.Join(sampleDir, "go.mod"))
	if err != nil {
		fmt.Println("  error:", err)
		return
	}
	var requires []string
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "github.com/") || strings.HasPrefix(line, "golang.org/") {
			fields := strings.Fields(line)
			if len(fields) >= 1 {
				requires = append(requires, fields[0])
			}
		}
	}
	imports := map[string]bool{}
	fset := token.NewFileSet()
	for _, f := range parseFiles(fset) {
		for _, imp := range f.Imports {
			imports[strings.Trim(imp.Path.Value, "\"")] = true
		}
	}
	found := false
	for _, r := range requires {
		if !imports[r] {
			fmt.Printf("  UNUSED DEP: %q required in go.mod but never imported\n", r)
			found = true
		}
	}
	if !found {
		fmt.Println("  no unused dependencies")
	}
	fmt.Println()
}

func auditUnusedImports() {
	fmt.Println("--- [2] UNUSED IMPORTS ---")
	fset := token.NewFileSet()
	for _, f := range parseFiles(fset) {
		used := map[string]bool{}
		ast.Inspect(f, func(n ast.Node) bool {
			if id, ok := n.(*ast.Ident); ok {
				used[id.Name] = true
			}
			return true
		})
		for _, imp := range f.Imports {
			name := importName(imp)
			if !used[name] {
				fmt.Printf("  UNUSED IMPORT: %s (imported at %s)\n",
					imp.Path.Value, fset.Position(imp.Pos()))
			}
		}
	}
	fmt.Println()
}

func auditShadowing() {
	fmt.Println("--- [3] SHADOWED NAMES ---")
	fset := token.NewFileSet()
	for _, f := range parseFiles(fset) {
		v := &shadowVisitor{fset: fset, scopes: []map[string]bool{{}}}
		var stack []ast.Node
		ast.Inspect(f, func(n ast.Node) bool {
			if n != nil {
				stack = append(stack, n)
				v.Enter(n)
				return true
			}
			v.Leave(stack[len(stack)-1])
			stack = stack[:len(stack)-1]
			return true
		})
	}
	fmt.Println()
}

type shadowVisitor struct {
	fset   *token.FileSet
	scopes []map[string]bool
}

func (v *shadowVisitor) Enter(n ast.Node) {
	switch node := n.(type) {
	case *ast.FuncDecl:
		v.scopes = append(v.scopes, map[string]bool{})
		if node.Type.Params != nil {
			for _, p := range node.Type.Params.List {
				for _, name := range p.Names {
					v.scopes[len(v.scopes)-1][name.Name] = true
				}
			}
		}
	case *ast.BlockStmt:
		v.scopes = append(v.scopes, map[string]bool{})
	case *ast.AssignStmt:
		if node.Tok == token.DEFINE {
			for _, e := range node.Lhs {
				if id, ok := e.(*ast.Ident); ok && id.Name != "_" {
					v.check(id.Name)
					v.scopes[len(v.scopes)-1][id.Name] = true
				}
			}
		}
	case *ast.ValueSpec:
		for _, name := range node.Names {
			if name.Name != "_" {
				v.check(name.Name)
				v.scopes[len(v.scopes)-1][name.Name] = true
			}
		}
	}
}

func (v *shadowVisitor) Leave(n ast.Node) {
	switch n.(type) {
	case *ast.FuncDecl, *ast.BlockStmt:
		v.scopes = v.scopes[:len(v.scopes)-1]
	}
}

func (v *shadowVisitor) check(name string) {
	for i := 0; i < len(v.scopes)-1; i++ {
		if v.scopes[i][name] {
			fmt.Printf("  SHADOWED: %q redeclared in an inner scope\n", name)
			return
		}
	}
}

func auditDuplication() {
	fmt.Println("--- [4] DUPLICATED LOGIC ---")
	fset := token.NewFileSet()
	type fn struct {
		name string
		norm string
	}
	var fns []fn
	for _, f := range parseFiles(fset) {
		for _, decl := range f.Decls {
			if fd, ok := decl.(*ast.FuncDecl); ok && fd.Body != nil {
				fns = append(fns, fn{fd.Name.Name, normalize(fd.Body)})
			}
		}
	}
	found := false
	for i := 0; i < len(fns); i++ {
		for j := i + 1; j < len(fns); j++ {
			if fns[i].norm == fns[j].norm {
				fmt.Printf("  DUPLICATED: %s() and %s() have identical logic\n",
					fns[i].name, fns[j].name)
				found = true
			}
		}
	}
	if !found {
		fmt.Println("  no duplicated logic found")
	}
	fmt.Println()
}

func normalize(n ast.Node) string {
	var buf bytes.Buffer
	ast.Inspect(n, func(x ast.Node) bool {
		switch x.(type) {
		case *ast.Ident:
			buf.WriteString("X")
		case *ast.BasicLit:
			buf.WriteString("L")
		case *ast.BinaryExpr:
			buf.WriteString("OP")
		case *ast.ReturnStmt:
			buf.WriteString("RET")
		case *ast.IfStmt:
			buf.WriteString("IF")
		case *ast.AssignStmt:
			buf.WriteString("ASGN")
		}
		return true
	})
	return buf.String()
}

func auditDeadCode() {
	fmt.Println("--- [5] DEAD CODE (declared but never referenced) ---")
	fset := token.NewFileSet()
	files := parseFiles(fset)
	declared := map[string]string{}
	declPos := map[token.Pos]bool{}
	referenced := map[string]bool{}
	for _, f := range files {
		for _, decl := range f.Decls {
			switch d := decl.(type) {
			case *ast.FuncDecl:
				declared[d.Name.Name] = "func"
				declPos[d.Name.Pos()] = true
			case *ast.GenDecl:
				for _, spec := range d.Specs {
					if vs, ok := spec.(*ast.ValueSpec); ok {
						for _, name := range vs.Names {
							declared[name.Name] = "var"
							declPos[name.Pos()] = true
						}
					}
				}
			}
		}
		ast.Inspect(f, func(n ast.Node) bool {
			if id, ok := n.(*ast.Ident); ok && !declPos[id.Pos()] {
				referenced[id.Name] = true
			}
			return true
		})
	}
	var dead []string
	for name, kind := range declared {
		if name == "main" || isExported(name) {
			continue
		}
		if !referenced[name] {
			dead = append(dead, fmt.Sprintf("%s %s", kind, name))
		}
	}
	sort.Strings(dead)
	if len(dead) == 0 {
		fmt.Println("  no dead code found")
	} else {
		for _, d := range dead {
			fmt.Printf("  DEAD: %s is declared but never referenced\n", d)
		}
	}
	fmt.Println()
}
