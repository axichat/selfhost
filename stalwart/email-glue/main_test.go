package main

import (
	"errors"
	"net/http"
	"testing"
)

func TestClientStalwartErrorMapsFieldAlreadyExists(t *testing.T) {
	status, payload := clientStalwartError(&stalwartAPIError{
		Op:     "create principal",
		Status: http.StatusConflict,
		Code:   "fieldAlreadyExists",
	})

	if status != http.StatusConflict {
		t.Fatalf("status = %d, want %d", status, http.StatusConflict)
	}
	if got := payload["error"]; got != "account_exists" {
		t.Fatalf("error = %v, want account_exists", got)
	}
	if got := payload["reason"]; got != "fieldAlreadyExists" {
		t.Fatalf("reason = %v, want fieldAlreadyExists", got)
	}
}

func TestClientStalwartErrorMapsUnavailable(t *testing.T) {
	status, payload := clientStalwartError(&stalwartAPIError{
		Op:  "create principal",
		Err: errors.New("connection refused"),
	})

	if status != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", status, http.StatusServiceUnavailable)
	}
	if got := payload["error"]; got != "mail_service_unavailable" {
		t.Fatalf("error = %v, want mail_service_unavailable", got)
	}
}

func TestWithPrincipalIdentifiersFallsBackToName(t *testing.T) {
	client := &stalwartClient{}
	var tried []string

	err := client.withPrincipalIdentifiers("patch principal", principalRef{
		ID:   "42",
		Name: "alice",
	}, func(identifier string) error {
		tried = append(tried, identifier)
		if identifier == "42" {
			return &stalwartAPIError{
				Op:     "patch principal",
				Status: http.StatusNotFound,
				Code:   "notFound",
			}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("withPrincipalIdentifiers returned error: %v", err)
	}
	if len(tried) != 2 || tried[0] != "42" || tried[1] != "alice" {
		t.Fatalf("tried = %v, want [42 alice]", tried)
	}
}

func TestWithPrincipalIdentifiersReturnsNotFoundAfterAllCandidates(t *testing.T) {
	client := &stalwartClient{}

	err := client.withPrincipalIdentifiers("patch principal", principalRef{
		ID:   "42",
		Name: "alice",
	}, func(identifier string) error {
		return &stalwartAPIError{
			Op:     "patch principal",
			Status: http.StatusNotFound,
			Code:   "notFound",
		}
	})
	if err == nil {
		t.Fatal("withPrincipalIdentifiers returned nil error")
	}
	if !isStalwartErrorCode(err, "notFound") {
		t.Fatalf("error = %v, want notFound", err)
	}
}
