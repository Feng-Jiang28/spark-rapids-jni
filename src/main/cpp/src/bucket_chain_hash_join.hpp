/*
 * Copyright (c) 2019-2024, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

namespace spark_rapids_jni {
    std::unique_ptr<cudf::table_view> join_gather_maps(
        cudf::table_view const& left_table,
        cudf::table_view const& right_table,
        bool compare_nulls_equal,
        rmm::device_async_resource_ref mr = rmm::mr::get_current_device_resource()
    );
}