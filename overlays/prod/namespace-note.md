The prod overlay targets the `canopy-prod` namespace but still inherits the
`canopy` Namespace object from `base/namespace.yaml`. In a real setup the
Namespace would be moved out of base and declared per overlay. It is kept
simple here on purpose: this overlay is reference material and has not been
applied, since there is no real cluster or domain behind it.
