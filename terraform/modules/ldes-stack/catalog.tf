/**
 * Everything the LDES server, LDIO and the PostgreSQL sink need is derived from
 * catalog/streams.json here, so that the event stream definitions, the view definitions, the
 * SPARQL sink queries and the table definitions can never drift apart.
 *
 * The rendered Turtle follows the shapes the LDES server actually validates against:
 *
 *  - an event stream document must carry ldes:timestampPath, ldes:versionOfPath and tree:shape,
 *    and may not contain any subject that is not referenced from the stream itself, which is why
 *    the views are configured separately;
 *  - a view document is a tree:Node with exactly one tree:fragmentationStrategy list; time based
 *    fragmentation is tree:HierarchicalTimeBasedFragmentation (there is no tree:Timebased-
 *    Fragmentation), geospatial fragmentation is tree:GeospatialFragmentation;
 *  - tree:pageSize and tree:maxZoom must be typed numeric literals.
 */

locals {
  catalog = var.streams_catalog

  # ------------------------------------------------------------------------------------------
  # Event streams
  # ------------------------------------------------------------------------------------------

  stream_configurations = {
    for stream in local.catalog.streams : stream.name => <<-TTL
      @prefix ldes:   <https://w3id.org/ldes#> .
      @prefix tree:   <https://w3id.org/tree#> .
      @prefix sh:     <http://www.w3.org/ns/shacl#> .
      @prefix server: <${local.ldes_server_public_url}/> .
      @prefix es:     <${local.ldes_server_public_url}/${stream.name}/> .

      server:${stream.name} a ldes:EventStream ;
          ldes:timestampPath <${local.catalog.timestampPath}> ;
          ldes:versionOfPath <${local.catalog.versionOfPath}> ;
          ldes:createVersions false ;
          tree:shape es:shape .

      es:shape a sh:NodeShape .
    TTL
  }

  # ------------------------------------------------------------------------------------------
  # Views
  # ------------------------------------------------------------------------------------------

  view_pairs = flatten([
    for stream in local.catalog.streams : [
      for view in stream.views : {
        key    = "${stream.name}/${view.name}"
        stream = stream.name
        view   = view
      }
    ]
  ])

  fragmentation_strategies = {
    for pair in local.view_pairs : pair.key => (
      pair.view.kind == "geospatial" ? join("\n", [
        "([",
        "      a tree:GeospatialFragmentation ;",
        "      tree:maxZoom \"${pair.view.maxZoom}\"^^xsd:integer ;",
        "      tree:fragmentationPath <${local.catalog.geometryPath}>",
        "    ])",
        ]) : pair.view.kind == "timebased" ? join("\n", [
        "([",
        "      a tree:HierarchicalTimeBasedFragmentation ;",
        "      tree:maxGranularity \"${pair.view.maxGranularity}\" ;",
        "      tree:fragmentationPath <${local.catalog.timestampPath}>",
        "    ])",
      ]) : "()"
    )
  }

  view_configurations = {
    for pair in local.view_pairs : pair.key => <<-TTL
      @prefix tree: <https://w3id.org/tree#> .
      @prefix xsd:  <http://www.w3.org/2001/XMLSchema#> .

      </${pair.key}> a tree:Node ;
        tree:viewDescription [
          a tree:ViewDescription ;
          tree:fragmentationStrategy ${local.fragmentation_strategies[pair.key]} ;
          tree:pageSize "${pair.view.pageSize}"^^xsd:integer
        ] .
    TTL
  }

  streams = [
    for stream in local.catalog.streams : {
      name          = stream.name
      configuration = local.stream_configurations[stream.name]

      views = [
        for view in stream.views : {
          name          = view.name
          configuration = local.view_configurations["${stream.name}/${view.name}"]
        }
      ]
    }
  ]

  # ------------------------------------------------------------------------------------------
  # SPARQL sink queries
  #
  # Ldio:LdioRdbOut uses the SELECT variable names verbatim as column names, and binds the Java
  # object Jena produces for each value. Only xsd:dateTime, xsd:double and xsd:int map onto a
  # type the PostgreSQL driver accepts, so every other column is forced to a plain string with
  # STR(). Each pattern is written on its own line with a repeated subject: property paths keep
  # the nested blank nodes of the complex streams readable, and a single triple pattern per line
  # makes the generated query easy to diff.
  # ------------------------------------------------------------------------------------------

  column_paths = {
    for pair in flatten([
      for stream in local.catalog.streams : [
        for column in stream.sink.columns : {
          key    = "${stream.name}.${column.name}"
          column = column
          path = try(column.role, "") == "member" ? ["<${local.catalog.versionOfPath}>"] : (
            try(column.role, "") == "timestamp" ? ["<${local.catalog.timestampPath}>"] : [
              for step in try(column.path, []) :
              "<${local.catalog.prefixes[split(":", step)[0]]}${split(":", step)[1]}>"
            ]
          )
        }
      ]
    ]) : pair.key => pair
  }

  sink_queries = {
    for stream in local.catalog.streams : stream.name => join("\n", concat(
      [
        "SELECT ${join(" ", [
          for column in stream.sink.columns :
          try(column.role, "") == "version" ? "(STR(?s) AS ?version_id)" : (
            local.catalog.types[column.type].project == "str"
            ? "(STR(?${column.name}_raw) AS ?${column.name})"
            : "?${column.name}"
          )
        ])}",
        "WHERE {",
      ],
      [
        for column in stream.sink.columns :
        "    ?s ${join("/", local.column_paths["${stream.name}.${column.name}"].path)} ?${column.name}${local.catalog.types[column.type].project == "str" ? "_raw" : ""} ."
        if try(column.role, "") != "version"
      ],
      ["}"],
    ))
  }

  # ------------------------------------------------------------------------------------------
  # Sink schema
  #
  # Only the three columns that identify a member are NOT NULL: a missing property makes the
  # SPARQL basic graph pattern fail to match, so the member produces no row at all rather than a
  # row with holes, and the row count check is what catches it. A NOT NULL on every column would
  # only turn that into a pipeline crash.
  #
  # `ingested_at` is not part of the SPARQL projection; PostgreSQL fills it in, which is what
  # makes the replication lag measurable afterwards.
  # ------------------------------------------------------------------------------------------

  sink_tables = [for stream in local.catalog.streams : stream.sink.table]

  sink_table_ddl = join("\n\n", [
    for stream in local.catalog.streams : join("\n", concat(
      ["CREATE TABLE IF NOT EXISTS ${stream.sink.table} ("],
      [
        for column in stream.sink.columns :
        "    ${column.name} ${local.catalog.types[column.type].sql}${contains(["version", "member", "timestamp"], try(column.role, "")) ? " NOT NULL" : ""},"
      ],
      [
        "    ingested_at timestamptz NOT NULL DEFAULT now(),",
        "    PRIMARY KEY (version_id)",
        ");",
        "",
        "CREATE INDEX IF NOT EXISTS ${stream.sink.table}_member_id_idx ON ${stream.sink.table} (member_id);",
        "CREATE INDEX IF NOT EXISTS ${stream.sink.table}_created_at_idx ON ${stream.sink.table} (created_at);",
        "CREATE INDEX IF NOT EXISTS ${stream.sink.table}_ingested_at_idx ON ${stream.sink.table} (ingested_at);",
      ],
    ))
  ])

  # ------------------------------------------------------------------------------------------
  # Endpoints, published as outputs for the load test and the workflow
  # ------------------------------------------------------------------------------------------

  stream_endpoints = {
    for stream in local.catalog.streams : stream.name => {
      ingest_url      = "${local.ldes_server_public_url}/${stream.name}"
      sink_table      = stream.sink.table
      replication_url = "${local.ldes_server_public_url}/${stream.name}/${stream.replicationView}"

      views = {
        for view in stream.views : view.name => "${local.ldes_server_public_url}/${stream.name}/${view.name}"
      }
    }
  }

  view_urls = [for pair in local.view_pairs : "${local.ldes_server_public_url}/${pair.key}"]
}
