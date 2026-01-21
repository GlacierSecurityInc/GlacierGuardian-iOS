# 🚀 Copilot Project Instructions: High-Quality PR Generation

These instructions guide GitHub Copilot to generate production-grade pull requests that align with this repository's architecture, patterns, tests, and review expectations.

Copilot must follow the structured workflow below *every time* it generates code or a PR.

---

## 🔵 STEP 1 — Deep Repository & Task Analysis (No Code)
Before writing code, analyze the task thoroughly.

Copilot must:

1. Restate the task in its own words to ensure understanding.
2. Identify all relevant files, modules, components, utilities, data models, test files, and architectural patterns that affect this work.
3. Infer the repository’s coding conventions, abstractions, naming patterns, and style guidelines.
4. List all constraints, edge cases, and potential integration risks.
5. Identify any ambiguous requirements and resolve them using engineering best practices.

**No code is allowed in this step.**

---

## 🔵 STEP 2 — Implementation Plan
Create a detailed plan including:

- Files to add, remove, or modify  
- Functions, classes, or components to create or update  
- Expected API, behavior, inputs, and outputs  
- Error handling and validation strategy  
- Security and safety considerations  
- Performance implications  
- Required documentation changes  
- Test strategy, including exact tests to add or update

Copilot must wait for human approval before writing code—unless the user explicitly instructs to continue.

---

## 🔵 STEP 3 — Pre-Coding Self-Review (Simulated PR Review)
Before generating code, Copilot must run a hypothetical review using criteria similar to automated PR review tools:

- Code correctness and completeness  
- Maintainability and readability  
- Test coverage and deterministic behavior  
- Type safety and API consistency  
- Security and input validation  
- Performance considerations  
- Repo architecture and style compliance  
- Known patterns and abstractions used in this codebase  

Copilot must refine the implementation plan until it predicts **zero review-blocking issues**.

---

## 🔵 STEP 4 — Code Generation (Unified Diff Preferred)
Copilot may only write code after completing Steps 1–3.

Requirements:

- Follow the established patterns and conventions in this repository.
- Prefer minimal, isolated, non-breaking changes unless explicitly directed otherwise.
- Ensure the code compiles, runs, and integrates with surrounding modules.
- For diffs: use unified diff format (`diff --git`) or structured file updates.
- Add full test coverage following the existing testing style.

All generated code must be complete, correct, and free from placeholders.

---

## 🔵 STEP 5 — Final Self-Check (Post-Generation Review)
After writing the code, Copilot must:

1. Re-run a simulated PR review against its own output.  
2. Check for typical issues the automated reviewer would flag:
   - Incorrect imports
   - Undefined variables or missing functions
   - Type mismatches
   - Unhandled errors
   - Runtime edge cases
   - Violations of project conventions
   - Missing tests or insufficient coverage
   - Security issues or insufficient input validation
3. Automatically fix all issues before finalizing the PR.

Copilot should only present the PR once it believes it would pass automated and human review.

---

## ✔️ Summary of Expectations
Copilot must:

- Think before coding  
- Plan before implementing  
- Review before submitting  
- Follow repository architecture and patterns  
- Produce review-ready pull requests, not drafts  
- Provide complete, correct, idiomatic, maintainable code  

---

**These instructions apply to all Copilot-generated PRs, changes, analyses, and code suggestions in this repository.**
