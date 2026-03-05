function run_solver_benchmarks(
  repo_name::AbstractString,
  bmark_dir::AbstractString;
  reference_branch::AbstractString = "main",
  gist_url::Union{AbstractString, Nothing} = nothing,
  script = "benchmarks.jl",
)

  update_gist = gist_url !== nothing
  is_git = isdir(joinpath(bmark_dir, "..", ".git"))
  @info "" is_git update_gist

  local gist_id
  if update_gist
    gist_id = split(gist_url, "/")[end]
    @info "" gist_id
  end

  # if we are running these benchmarks from the git repository
  # we want to develop the package instead of using the release
  if is_git
    Pkg.develop(PackageSpec(path = joinpath(bmark_dir, "..")))
  else
    Pkg.activate(bmark_dir)
  end
  Pkg.instantiate()

  # name the benchmark after the repo or the sha of HEAD
  bmarkname = is_git ? readchomp(`$git rev-parse HEAD`) : lowercase(repo_name)
  @info "" bmarkname

  # Run the benchmark script on this commit
  this_commit = Base.include(Main, joinpath(bmark_dir, script))
  @assert this_commit isa Dict{Symbol, DataFrame} "Expected the benchmark script to return a Dict{Symbol, DataFrame}, but got $(typeof(this_commit)). Make sure your benchmark script returns a dict resulting from BenchmarkSolver.bmark_solver function"

  # Run the benchmark script on the reference branch
  local reference
  if is_git
    #reference = _withcommit(f, repo_name, reference_branch)
  end

end


# Runs a script at a commit on a repo and afterwards goes back
# to the original commit / branch.
# This code is based on https://github.com/JuliaCI/PkgBenchmark.jl/blob/master/src/util.jl
function _withcommit(script, repo, commit)
  original_commit = _shastring(repo, "HEAD")
  LibGit2.transact(repo) do r
    branch = try LibGit2.branch(r) catch err; nothing end
    try
      LibGit2.checkout!(r, _shastring(r, commit))
      f()
    catch err
        rethrow(err)
    finally
      if branch !== nothing
        LibGit2.branch!(r, branch)
      else
        LibGit2.checkout!(r, original_commit)
      end
    end
  end
end

_shastring(r::LibGit2.GitRepo, targetname) = string(LibGit2.revparseid(r, targetname))
_shastring(dir::AbstractString, targetname) = LibGit2.with(r -> _shastring(r, targetname), LibGit2.GitRepo(dir))
