defmodule TestLens.Git do
  @moduledoc """
  Best-effort git context for a run, captured by shelling `git` in a working
  directory. Every probe is wrapped: a missing repo, a missing `git` binary, or
  any non-zero exit yields `nil` for that field and never raises, so a test suite
  is never broken by git.

  No network is performed — `merge_base` reflects only what the local repository
  already knows. A caller that wants a fresh merge-base against the remote should
  `git fetch` *before* the run; see `SPEC.md`.

      TestLens.Git.context(File.cwd!())
      #=> %{branch: "main", commit: "a1b2c3…", base_ref: "origin/main", merge_base: "a1b2c3…"}
  """

  @typedoc "Resolved git context for a run. Every field is best-effort and may be nil."
  @type t :: %{
          branch: String.t() | nil,
          commit: String.t() | nil,
          base_ref: String.t() | nil,
          merge_base: String.t() | nil
        }

  # Candidate default bases, tried in order; the first that resolves wins. The
  # upstream of the current branch is the final fallback.
  @base_candidates ["origin/main", "origin/master"]

  @doc """
  Resolve the git context for `cwd`. Returns a map with `:branch`, `:commit`,
  `:base_ref` and `:merge_base`; any field git can't answer locally is `nil`.
  """
  @spec context(Path.t()) :: t()
  def context(cwd) do
    base_ref = resolve_base_ref(cwd)

    %{
      branch: git(cwd, ["rev-parse", "--abbrev-ref", "HEAD"]),
      commit: git(cwd, ["rev-parse", "HEAD"]),
      base_ref: base_ref,
      merge_base: base_ref && git(cwd, ["merge-base", "HEAD", base_ref])
    }
  end

  # The first of origin/main, origin/master, or the branch upstream that resolves
  # to a commit locally. Returns the ref *name* that was used (e.g. "origin/main").
  defp resolve_base_ref(cwd) do
    resolved =
      Enum.find(@base_candidates, fn ref ->
        git_ok?(cwd, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"])
      end)

    resolved || git(cwd, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
  end

  # Run git, returning trimmed stdout on exit 0, otherwise nil. Never raises.
  defp git(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> nilify_empty()
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp git_ok?(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp nilify_empty(""), do: nil
  defp nilify_empty(s), do: s
end
