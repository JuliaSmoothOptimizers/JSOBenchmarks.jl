module JSOBenchmarks

# stdlib modules
using Pkg

# Third-party modules
using DataFrames
using DocStringExtensions
using Git
using GitHub
using JLD2
using JSON
using PkgBenchmark
using Plots

# JSO modules
using SolverBenchmark

export run_benchmarks
export profile_solvers_from_pkgbmark
export create_gist_from_json_dict, create_gist_from_json_file
export update_gist_from_json_dict, update_gist_from_json_file
export write_md

const git = Git.git()

# use: run_benchmarks.jl repository_name gist_url
#
# example: run_benchmarks.jl LimitedLDLFactorizations.jl https://gist.github.com/dpo/911c1e3b9d341d5cddb61deb578d8ed3

"""
Run benchmarks from a repository, compare against a reference branch and post results to a gist.

$(TYPEDSIGNATURES)

This method is intended to be called from a pull request.
"""
function run_benchmarks(
  repo_name::AbstractString,
  gist_url::AbstractString,
  bmark_dir::AbstractString;
  reference_branch::AbstractString = "main",
)

  # const repo_name = string(split(ARGS[1], ".")[1])
  # const gist_url = ARGS[2]
  gist_id = split(gist_url, "/")[end]
  # const reference_branch = length(ARGS) > 2 ? ARGS[3] : "main"

  # if we are running these benchmarks from the git repository
  # we want to develop the package instead of using the release
  # const bmark_dir = @__DIR__
  isgit = isdir(joinpath(bmark_dir, "..", ".git"))
  if isgit
    Pkg.develop(PackageSpec(url = joinpath(bmark_dir, "..")))
  else
    Pkg.activate(bmark_dir)
    Pkg.instantiate()
  end

  # name the benchmark after the repo or the sha of HEAD
  cd(bmark_dir)
  bmarkname = isgit ? readchomp(`$git rev-parse HEAD`) : lowercase(repo_name)

  # Begin benchmarks
  # NB: benchmarkpkg will run benchmarks/benchmarks.jl by default

  commit = benchmarkpkg(repo_name)  # current state of repository
  local reference
  local judgement
  if isgit
    reference = benchmarkpkg(repo_name, reference_branch)
    judgement = judge(commit, reference)
  end

  commit_stats = bmark_results_to_dataframes(commit)
  export_markdown("$(bmarkname).md", commit)
  local reference_stats
  local judgement_stats
  if isgit
    reference_stats = bmark_results_to_dataframes(reference)
    judgement_stats = judgement_results_to_dataframes(judgement)
    export_markdown("judgement_$(bmarkname).md", judgement)
    export_markdown("reference.md", reference)
  end

  # extract stats for each benchmark to plot profiles
  # files_dict will be part of json_dict below
  files_dict = Dict{String, Any}()
  if isgit
    for k ∈ keys(judgement_stats)
      # k is the name of a benchmark suite
      k_stats =
        Dict{Symbol, DataFrame}(:commit => commit_stats[k], :reference => reference_stats[k])

      # save benchmark data to jld2 file
      save_stats(k_stats, "$(bmarkname)_vs_reference_$(k).jld2", force = true)

      _ = profile_solvers_from_pkgbmark(k_stats)
      savefig("profiles_commit_vs_reference_$(k).svg")  # for the artefacts
      # savefig("profiles_commit_vs_reference_$(k).png")  # for the markdown summary
      # read contents of svg file to add to gist
      k_svgfile = open("profiles_commit_vs_reference_$(k).svg", "r") do fd
        readlines(fd)
      end
      files_dict["$(k).svg"] = Dict{String, Any}("content" => join(k_svgfile))
    end
  end

  mdfiles = [:commit]
  if isgit
    push!(mdfiles, :reference)
    push!(mdfiles, :judgement)
  end
  for mdfile ∈ mdfiles
    files_dict["$(mdfile).md"] =
      Dict{String, Any}("content" => "$(sprint(export_markdown, eval(mdfile)))")
  end

  if isgit
    # save judgement data to jld2 file
    jldopen("$(bmarkname)_vs_reference_judgement.jld2", "w") do file
      file["jstats"] = judgement_stats
    end
  end

  # json description of gist
  json_dict = Dict{String, Any}(
    "description" => "$(repo_name) repository benchmark",
    "public" => true,
    "files" => files_dict,
    "gist_id" => gist_id,
  )

  gist_json = "$(bmarkname).json"
  open(gist_json, "w") do f
    JSON.print(f, json_dict)
  end

  # posted_gist = create_gist_from_json_dict(json_dict)
  update_gist_from_json_dict(gist_id, json_dict)

  isgit && write_simple_md_report("$(bmarkname).md")

  return nothing
end

# Utility functions

"""
Produce performance profiles from PkgBenchmark results.

$(TYPEDSIGNATURES)

The profiles produced are with respect to time, memory, garbage collection time and allocations.
"""
function profile_solvers_from_pkgbmark(stats::Dict{Symbol, DataFrame})
  # guard against zero gctimes
  costs =
    [df -> df[!, :time], df -> df[!, :memory], df -> df[!, :gctime] .+ 1, df -> df[!, :allocations]]
  profile_solvers(stats, costs, ["time", "memory", "gctime+1", "allocations"])
end

"""
Create a new gist from a JSON dictionary.

$(TYPEDSIGNATURES)

Return the new gist.
"""
function create_gist_from_json_dict(json_dict)
  myauth = GitHub.authenticate(ENV["GITHUB_AUTH"])
  posted_gist = create_gist(params = json_dict, auth = myauth)
  return posted_gist
end

"""
Read a JSON dictionary from file and use it to create a new gist.

$(TYPEDSIGNATURES)

Return the value of `create_gist_from_json_dict()`.
"""
function create_gist_from_json_file(gistfile = "gist.json")
  json_dict = begin
    open(gistfile, "r") do f
      return JSON.parse(f)
    end
  end
  return create_gist_from_json_dict(json_dict)
end

"""
Update an existing gist from a JSON dictionary.

$(TYPEDSIGNATURES)

Return the value of `GitHub.edit_gist()`.
"""
function update_gist_from_json_dict(gist_id, json_dict)
  myauth = GitHub.authenticate(ENV["GITHUB_AUTH"])
  existing_gist = gist(gist_id)
  return edit_gist(existing_gist, params = json_dict, auth = myauth)
end

"""
Read a JSON dictionary from file and use it to update an existing gist.

$(TYPEDSIGNATURES)

Return the value of `update_gist_from_json_dict()`.
"""
function update_gist_from_json_file(gist_id, gistfile = "gist.json")
  json_dict = begin
    open(gistfile, "r") do f
      return JSON.parse(f)
    end
  end
  return update_gist_from_json_dict(gist_id, json_dict)
end

function write_md(io::IO, title::AbstractString, results)
  println(io, "<details>")
  println(io, "<summary>$(title)</summary>")
  println(io, "<br>")
  println(io, sprint(export_markdown, results))
  println(io, "</details>")
end

"""
Write a simple Markdown report to file that can be used to comment a pull request.

$(TYPEDSIGNATURES)
"""
function write_simple_md_report(fname::AbstractString)
  # simpler markdown summary to post in pull request
  open(fname, "w") do f
    println(f, "### Benchmark results")
    for k ∈ keys(judgement_stats)
      # TODO: missing a URL for the png
      println(f, "![$(k) profiles](profiles_commit_vs_reference_$(k).png $(string(k)))")
      println(f, "<br>")
    end
    write_md(f, "Judgement", judgement)
    println(f, "<br>")
    write_md(f, "Commit", commit)
    println(f, "<br>")
    write_md(f, "Reference", reference)
  end
end

end # module JSOBenchmarks
