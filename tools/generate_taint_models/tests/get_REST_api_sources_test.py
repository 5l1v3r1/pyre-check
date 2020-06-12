# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-unsafe

import unittest
from unittest.mock import MagicMock

from ..generator_specifications import AnnotationSpecification, WhitelistSpecification
from ..get_REST_api_sources import RESTApiSourceGenerator
from .test_functions import __name__ as qualifier, all_functions


class GetRESTApiSourcesTest(unittest.TestCase):
    def test_compute_models(self) -> None:
        # Test with default arguments
        source = "Taint"
        self.assertEqual(
            [
                *map(
                    str,
                    RESTApiSourceGenerator(
                        django_urls=MagicMock(), taint_annotation=source
                    ).compute_models(all_functions),
                )
            ],
            [
                f"def {qualifier}.TestClass.methodA(self, x: {source}): ...",
                f"def {qualifier}.TestClass.methodB(self, *args: {source})" ": ...",
                f"def {qualifier}.testA(): ...",
                f"def {qualifier}.testB(x: {source}): ...",
                f"def {qualifier}.testC(x: {source}): ...",
                f"def {qualifier}.testD(x: {source}, *args: {source}): ...",
                f"def {qualifier}.testE(x: {source}, **kwargs: {source}): ...",
            ],
        )

        # Test with old-style whitelisting
        self.assertEqual(
            [
                *map(
                    str,
                    RESTApiSourceGenerator(
                        django_urls=MagicMock(),
                        whitelisted_classes=["int"],
                        whitelisted_views=[f"{qualifier}.testA"],
                        taint_annotation=source,
                    ).compute_models(all_functions),
                )
            ],
            [
                f"def {qualifier}.TestClass.methodA(self: {source}, x): ...",
                f"def {qualifier}.TestClass.methodB(self: {source}, *args: {source})"
                ": ...",
                f"def {qualifier}.testB(x: {source}): ...",
                f"def {qualifier}.testC(x): ...",
                f"def {qualifier}.testD(x, *args): ...",
                f"def {qualifier}.testE(x, **kwargs: {source}): ...",
            ],
        )

        # Test with AnnotationSpecification
        self.assertEqual(
            [
                *map(
                    str,
                    RESTApiSourceGenerator(
                        django_urls=MagicMock(),
                        annotations=AnnotationSpecification(
                            arg="Arg", vararg="VarArg", kwarg="KWArg", returns="Returns"
                        ),
                    ).compute_models(all_functions),
                )
            ],
            [
                f"def {qualifier}.TestClass.methodA(self, x: Arg) -> Returns: ...",
                f"def {qualifier}.TestClass.methodB(self, *args: VarArg)"
                " -> Returns: ...",
                f"def {qualifier}.testA() -> Returns: ...",
                f"def {qualifier}.testB(x: Arg) -> Returns: ...",
                f"def {qualifier}.testC(x: Arg) -> Returns: ...",
                f"def {qualifier}.testD(x: Arg, *args: VarArg) -> Returns: ...",
                f"def {qualifier}.testE(x: Arg, **kwargs: KWArg) -> Returns: ...",
            ],
        )

        # Test with WhitelistSpecification
        self.assertEqual(
            [
                *map(
                    str,
                    RESTApiSourceGenerator(
                        django_urls=MagicMock(),
                        whitelisted_parameters=WhitelistSpecification(
                            parameter_name={"self"}, parameter_type={"int"}
                        ),
                        taint_annotation=source,
                    ).compute_models(all_functions),
                )
            ],
            [
                f"def {qualifier}.TestClass.methodA(self, x): ...",
                f"def {qualifier}.TestClass.methodB(self, *args: {source})" ": ...",
                f"def {qualifier}.testA(): ...",
                f"def {qualifier}.testB(x: {source}): ...",
                f"def {qualifier}.testC(x): ...",
                f"def {qualifier}.testD(x, *args): ...",
                f"def {qualifier}.testE(x, **kwargs: {source}): ...",
            ],
        )
