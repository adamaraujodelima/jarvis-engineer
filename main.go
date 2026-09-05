package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

type ClaudeResponse struct {
	SessionID string `json:"session_id"`
	Result    string `json:"result"`
}

type Agent struct {
	Name      string
	Prompt    string
	Role      string
	SessionID string
}

func (a *Agent) Run(ctx context.Context, prompt string) (string, error) {
	args := []string{
		"--append-system-prompt-file",
		"roles/" + a.Role,
		"-p",
		prompt,
		"--output-format",
		"json",
	}

	if a.SessionID != "" {
		args = append(args, "--resume", a.SessionID)
	}

	cmd := exec.CommandContext(ctx, "claude", args...)
	cmd.Dir = mustGetwd()

	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf(
			"%s failed: %w\n%s",
			a.Name,
			err,
			output,
		)
	}

	var response ClaudeResponse

	if err := json.Unmarshal(output, &response); err != nil {
		return "", fmt.Errorf(
			"invalid %s response: %w\n%s",
			a.Name,
			err,
			output,
		)
	}

	a.SessionID = response.SessionID

	return response.Result, nil
}

func mustGetwd() string {
	dir, err := os.Getwd()
	if err != nil {
		panic(err)
	}

	return dir
}

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()

	// read the task from the arguments
	if len(os.Args) < 2 {
		fmt.Println("Usage: go run main.go <task>")
		os.Exit(1)
	}

	task := strings.Join(os.Args[1:], " ")

	coder := Agent{
		Name: "coder",
		Role: "CODER.md",
	}

	reviewer := Agent{
		Name: "reviewer",
		Role: "REVIEWER.md",
	}

	for iteration := 1; iteration <= 5; iteration++ {
		fmt.Printf("\n=== ITERATION %d ===\n", iteration)

		// ------------------------------------------------------------
		// CODER
		// ------------------------------------------------------------

		coderPrompt := task

		if iteration > 1 {
			coderPrompt = fmt.Sprintf(`
				You previously implemented the requested task:

				%s

				The reviewer found these problems:

				%s`, task, reviewerFeedback)
		}

		fmt.Println("Running coder...")

		_, err := coder.Run(ctx, coderPrompt)
		if err != nil {
			panic(err)
		}

		// ------------------------------------------------------------
		// REVIEWER
		// ------------------------------------------------------------

		reviewPrompt := fmt.Sprintf(`
			Code review from the original task:

			%s

			Return exactly one of:

			APPROVED

			or:

			CHANGES_REQUIRED

			followed by a concise list of concrete problems.

			Do not request subjective changes.
			Only report actual problems.
		`, task)

		fmt.Println("Running reviewer...")

		review, err := reviewer.Run(ctx, reviewPrompt)
		if err != nil {
			panic(err)
		}

		fmt.Printf("\nREVIEW:\n%s\n", review)

		if strings.Contains(review, "APPROVED") && !strings.Contains(review, "CHANGES_REQUIRED") {
			fmt.Println("\nImplementation approved.")
			return
		}

		reviewerFeedback = review
	}

	fmt.Println("Maximum iterations reached.")
	os.Exit(1)
}

var reviewerFeedback string
