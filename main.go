// Minimal 3-step DAG (WithParents chain). Worker + one trigger in a single
// process, mirroring the SDK examples. Exits ~10s after triggering so the
// Makefile can chain it. Reads HATCHET_CLIENT_* from the environment.
package main

import (
	"context"
	"log"
	"time"

	hatchet "github.com/hatchet-dev/hatchet/sdks/go"
)

type In struct {
	Value int `json:"value"`
}

type Out struct {
	N int `json:"n"`
}

func main() {
	c, err := hatchet.NewClient()
	if err != nil {
		log.Fatal(err)
	}
	wf := c.NewWorkflow("repro-dag")
	s1 := wf.NewTask("step-1", func(ctx hatchet.Context, in In) (Out, error) { return Out{in.Value + 1}, nil })
	s2 := wf.NewTask("step-2", func(ctx hatchet.Context, in In) (Out, error) { return Out{in.Value + 2}, nil }, hatchet.WithParents(s1))
	_ = wf.NewTask("step-3", func(ctx hatchet.Context, in In) (Out, error) { return Out{in.Value + 3}, nil }, hatchet.WithParents(s2))

	w, err := c.NewWorker("repro-worker", hatchet.WithWorkflows(wf))
	if err != nil {
		log.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 13*time.Second)
	defer cancel()

	go func() {
		time.Sleep(3 * time.Second)
		ref, err := wf.RunNoWait(context.Background(), In{Value: 100})
		if err != nil {
			log.Fatal(err)
		}
		log.Printf("triggered run id=%s — worker stays up 10s so the 3 steps can run", ref.RunId)
	}()

	_ = w.StartBlocking(ctx)
}
