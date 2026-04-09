file(REMOVE_RECURSE
  "../lib/liboqs-internal.a"
  "../lib/liboqs-internal.pdb"
)

# Per-language clean rules from dependency scanning.
foreach(lang C)
  include(CMakeFiles/oqs-internal.dir/cmake_clean_${lang}.cmake OPTIONAL)
endforeach()
