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
  this_commit = include(joinpath(bmark_dir, script))
end