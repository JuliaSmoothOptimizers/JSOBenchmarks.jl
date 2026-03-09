function run_solver_benchmarks(
  repo_name::AbstractString,
  bmark_dir::AbstractString;
  reference_branch::AbstractString = "main",
  gist_url::Union{AbstractString, Nothing} = nothing,
  script = "benchmarks.jl",
  values = [(:elapsed_time, "CPU Time"), (:neval_obj, "# Objective Evals"), (:neval_grad, "# Gradient Evals")],
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
  @assert this_commit isa Dict{Symbol, DataFrame} "Expected the benchmark script to return a Dict{Symbol, DataFrame}, but got $(typeof(this_commit)). Make sure your benchmark script returns a dict resulting from BenchmarkSolver.bmark_solvers function"

  # Run the benchmark script on the reference branch
  local reference
  if is_git
    repo_dir = joinpath(bmark_dir, "..")
    repo = LibGit2.GitRepo(repo_dir)
    reference = _withcommit(joinpath(bmark_dir, script), repo, reference_branch)
  end

  # Plotting and tables
  files_dict = Dict{String, Any}()
  svgs = String[]
  stats_columns = [:name, :f, :t]
  hdr_override = Dict([:name => "Name", :f => "f(x)", :t => "Time"])
  tables = "# Solver Benchmarks Tables \n\n"
  if is_git
    for key in keys(this_commit)
      if haskey(reference, key)
        @info "Plotting $key"
        stats_subset = Dict(:this_commit => this_commit[key], :reference => reference[key])
        solved(df) = (df.status .== :first_order)
        costs = [df -> .!solved(df) * Inf + getproperty(df, value[1]) for value in values]
        costnames = [value[2] for value in values]

        p = profile_solvers(stats_subset, costs, costnames;xlabel = "", ylabel = "")
        tables *= pretty_stats(String, stats_subset[!, stats_columns], hdr_override = hdr_override, tf=tf_markdown)
        fname = "this_commit_vs_reference_$(key)"
        savefig("$(fname).svg")
        push!(svgs, "$(fname).svg")
        content = read("$(fname).svg", String)
        files_dict["$(fname).svg"] = Dict("content" => content)
      else
        @warn "$(reference_branch) branch benchmarks do not run the solver $key. Please update the benchmark solver list in a separate PR and rebase."
      end
    end
  end

  readme = "# $(repo_name) Solver Benchmarks\n\n"
  readme *= "Comparison between current commit and $(reference_branch).\n\n"

  files_dict["README.md"] = Dict("content" => readme)
  files_dict["TABLES.md"] = Dict("content" => tables)

  @info "creating or updating gist"
  # json description of gist
  json_dict = Dict{String, Any}(
    "description" => "$(repo_name) repository benchmark",
    "public" => true,
    "files" => files_dict,
  )

  if update_gist
    json_dict["gist_id"] = gist_id
  end

  gist_json = "$(bmarkname).json"
  open(gist_json, "w") do f
    JSON.print(f, json_dict)
  end

  local new_gist_url
  if update_gist
    update_gist_from_json_dict(gist_id, json_dict)
  else
    new_gist = create_gist_from_json_dict(json_dict)
    new_gist_url = string(new_gist.html_url)
  end

  @info "preparing simple Markdown report"
  is_git &&
    write_simple_md_report(
      "bmark_$(bmarkname).md",
      nothing,
      nothing,
      nothing,
      update_gist ? gist_url : new_gist_url,
      svgs,
    )
  
  @info "finished"
  return update_gist ? gist_url : new_gist_url
end


# Runs a script at a commit on a repo and afterwards goes back
# to the original commit / branch.
# This code is based on https://github.com/JuliaCI/PkgBenchmark.jl/blob/master/src/util.jl
function _withcommit(script, repo, commit)
  original_commit = string(LibGit2.GitHash(LibGit2.GitObject(repo, "HEAD")))
  local result
  LibGit2.transact(repo) do r
    branch = try LibGit2.branch(r) catch err; nothing end
    try
      LibGit2.checkout!(r, _shastring(r, commit))
      result = Base.include(Main, script)
      @assert result isa Dict{Symbol, DataFrame} "Expected the benchmark script to return a Dict{Symbol, DataFrame}, but got $(typeof(result)). Make sure your benchmark script returns a dict resulting from BenchmarkSolver.bmark_solvers function"
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
  return result
end

function _shastring(r::LibGit2.GitRepo, targetname)
  branch = LibGit2.lookup_branch(r, targetname)
  branch = branch === nothing ? LibGit2.lookup_branch(r, targetname, true) : branch # Search remote as well if not found locally.
  branch = branch === nothing ? LibGit2.lookup_branch(r, "origin/$(targetname)") : branch
  branch = branch === nothing ? LibGit2.lookup_branch(r, "origin/$(targetname)", true) : branch # Search remote as well if not found locally.
  @assert branch !== nothing "Branch $(targetname) not found in repository."
  return string(LibGit2.GitHash(LibGit2.GitObject(r, LibGit2.name(branch))))
end