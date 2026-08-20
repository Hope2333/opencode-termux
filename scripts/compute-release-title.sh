#!/usr/bin/env bash
set -euo pipefail

# scripts/compute-release-title.sh
# Accepts version strings on stdin, one per line.
# Outputs a compact version-range title for GitHub Release.

# --- Input ---
mapfile -t lines
if [ ${#lines[@]} -eq 0 ]; then
  echo "Error: no versions provided" >&2
  exit 1
fi

# --- Extract versions ---
declare -A seen
versions=()
for line in "${lines[@]}"; do
  # Extract first semver X.Y.Z from the line
  if [[ $line =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    v="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
    if [ -z "${seen[$v]:-}" ]; then
      seen[$v]=1
      versions+=("$v")
    fi
  fi
done

if [ ${#versions[@]} -eq 0 ]; then
  echo "Error: no versions provided" >&2
  exit 1
fi

# --- Sort versions descending (semver) ---
IFS=$'\n' sorted=($(sort -V -r <<<"${versions[*]}")); unset IFS

# --- Separate latest ---
latest="${sorted[0]}"
rest=("${sorted[@]:1}")

# --- Group by MAJOR.MINOR ---
declare -A groups
for v in "${rest[@]}"; do
  major="${v%%.*}"
  rest_v="${v#*.}"
  minor="${rest_v%%.*}"
  key="${major}.${minor}"
  patch="${v##*.}"
  if [ -z "${groups[$key]:-}" ]; then
    groups[$key]="$patch"
  else
    groups[$key]="${groups[$key]} $patch"
  fi
done

# --- Sort groups descending by MAJOR.MINOR ---
group_keys=()
for key in "${!groups[@]}"; do
  group_keys+=("$key")
done
IFS=$'\n' sorted_keys=($(sort -V -r <<<"${group_keys[*]}")); unset IFS

# --- Build result ---
result="v${latest}"

for key in "${sorted_keys[@]}"; do
  patches=(${groups[$key]})
  # Sort patches ascending
  IFS=$'\n' sorted_patches=($(sort -n <<<"${patches[*]}")); unset IFS

  # Find contiguous runs
  runs=()
  run_start="${sorted_patches[0]}"
  run_end="${sorted_patches[0]}"
  for ((i=1; i<${#sorted_patches[@]}; i++)); do
    p="${sorted_patches[$i]}"
    if [ $((p - run_end)) -eq 1 ]; then
      run_end=$p
    else
      if [ "$run_start" = "$run_end" ]; then
        runs+=("v${key}.${run_start}")
      else
        runs+=("v${key}.[${run_start}-${run_end}]")
      fi
      run_start=$p
      run_end=$p
    fi
  done
  # Last run
  if [ "$run_start" = "$run_end" ]; then
    runs+=("v${key}.${run_start}")
  else
    runs+=("v${key}.[${run_start}-${run_end}]")
  fi

  for run in "${runs[@]}"; do
    result="${result} ${run}"
  done
done

echo "$result"
