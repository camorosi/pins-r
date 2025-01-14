#' Use a LabKey folder as a board
#'
#' Pin data to a folder on a LabKey server
#'
#' `board_labkey()` is powered by the Rlabkey package <https://github.com/cran/Rlabkey>
#'
#' @inheritParams new_board
#' @param base_url Url of Labkey server
#' @param folder Folder within this server that this board will occupy
#' @param api_key API key to use for LabKey authentication. If not specified, will use `LABKEY_API_KEY`
#' @export
#' @examples
#' \dontrun{
#' board <- board_labkey("pins-test-labkey")
#' board %>% pin_write(mtcars)
#' board %>% pin_read("mtcars")
#' }
board_labkey <- function(
    board_alias = NULL,
    base_url,
    folder,
    subdir = "pins",
    versioned = TRUE,
    api_key = Sys.getenv("LABKEY_API_KEY"),
    cache = NULL
    ) {
  check_installed("Rlabkey")

  if (nchar(api_key) == 0) {
    stop("The 'labkey' board requires a 'api_key' parameter.")
  }
  if (nchar(base_url) == 0) {
    stop("The 'labkey' board requires a 'base_url' parameter for the LabKey server.")
  }
  if (nchar(folder) == 0) {
    stop("The 'labkey' board requires a 'folder' parameter for top folder to house the subdirectory for all pins")
  }

  # Globally sets the api_key and base_url
  Rlabkey::labkey.setDefaults(apiKey = api_key, baseUrl = base_url)
  # Rlabkey::labkey.acceptSelfSignedCerts()

  dirExists <- Rlabkey::labkey.webdav.pathExists(folderPath = folder, remoteFilePath = subdir)

  # Make labkey directory if does not exist
  if (!dirExists) {
    Rlabkey::labkey.webdav.mkDir(folderPath = folder, remoteFilePath = subdir)
  }

  cache <- cache %||% board_cache_path(paste0("labkey-", board_alias))
  new_board_v1("pins_board_labkey",
    name = "labkey",
    base_url = base_url,
    folder = folder,
    subdir = subdir,
    api_key = api_key,
    cache = cache,
    versioned = versioned
  )
}

#' @export
pin_list.pins_board_labkey <- function(board, ...) {
  resp <- labkey.webdav.listDir(
    baseUrl = board$base_url,
    folderPath = board$folder,
    remoteFilePath = board$subdir,
    fileSet='@files'
  )
  final_list <- resp$files

  paths <- fs::path_file(map_chr(final_list, ~ .$id))
  paths
}

#' @export
pin_exists.pins_board_labkey <- function(board, name, ...) {
  Rlabkey::labkey.webdav.pathExists(
    baseUrl = board$base_url,
    folderPath = board$folder,
    remoteFilePath = fs::path(board$subdir, name)
  )
}

#' @export
pin_delete.pins_board_labkey <- function(board, names, ...) {
  for (name in names) {
    check_pin_exists(board, name)
    Rlabkey::labkey.webdav.delete(
      baseUrl = board$base_url,
      folderPath = board$folder,
      remoteFilePath = fs::path(board$subdir, name),
      fileSet='@files'
    )
  }
  invisible(board)
}

#' @export
pin_version_delete.pins_board_labkey <- function(board, name, version, ...) {
  Rlabkey::labkey.webdav.delete(
    baseUrl = board$base_url,
    folderPath = board$folder,
    remoteFilePath = fs::path(board$subdir, name, version),
    fileSet='@files'
  )
}


#' @export
pin_versions.pins_board_labkey <- function(board, name, ...) {
  check_pin_exists(board, name)

  resp <- Rlabkey::labkey.webdav.listDir(
    baseUrl = board$base_url,
    folderPath = board$folder,
    remoteFilePath = fs::path(board$subdir, name),
    fileSet='@files'
  )

  final_list <- resp$files

  paths <- fs::path_file(map_chr(final_list, ~ .$id))
  version_from_path(paths)
}


#' @export
pin_meta.pins_board_labkey <- function(board, name, version = NULL, ...) {
  check_pin_exists(board, name)
  version <- check_pin_version(board, name, version)
  metadata_key <- fs::path(name, version, "data.txt")

  key_exists <- Rlabkey::labkey.webdav.pathExists(
    baseUrl = board$base_url,
    folderPath = board$folder,
    remoteFilePath = fs::path(board$subdir, metadata_key),
  )
  if (!key_exists) {
    abort_pin_version_missing(version)
  }

  path_version <- fs::path(board$cache, name, version)
  fs::dir_create(path_version)

  Rlabkey::labkey.webdav.get(
    baseUrl = board$base_url,
    folderPath = board$folder,
    remoteFilePath = fs::path(board$subdir, metadata_key),
    localFilePath = fs::path(board$cache, metadata_key)
  )
  local_meta(
    read_meta(fs::path(board$cache, name, version)),
    name = name,
    dir = path_version,
    version = version
  )
}

#' @export
pin_fetch.pins_board_labkey <- function(board, name, version = NULL, ...) {
  meta <- pin_meta(board, name, version = version)
  cache_touch(board, meta)

  for (file in meta$file) {
    key <- fs::path(name, meta$local$version, file)
    Rlabkey::labkey.webdav.get(
      baseUrl = board$base_url,
      folderPath = board$folder,
      remoteFilePath = fs::path(board$subdir, key),
      localFilePath = fs::path(board$cache, key)
    )
  }

  meta
}

#' @export
pin_store.pins_board_labkey <- function(board, name, paths, metadata,
                                        versioned = NULL, x = NULL, ...) {
  ellipsis::check_dots_used()
  check_pin_name(name)
  # version name is timestamp + first 5 chr of hash
  version <- version_setup(board, name, version_name(metadata), versioned = versioned)

  version_dir <- fs::path(name, version)
  # write data.txt to tmp file
  yaml_path <- fs::path_temp("data.txt")
  yaml::write_yaml(x = metadata, file = yaml_path)
  withr::defer(fs::file_delete(yaml_path))
  Rlabkey::labkey.webdav.put(localFile = yaml_path,
                             baseUrl = board$base_url,
                             folderPath = board$folder,
                             remoteFilePath = fs::path(board$subdir, version_dir, "data.txt"))
  for (path in paths) {
    Rlabkey::labkey.webdav.put(localFile = path,
                               baseUrl = board$base_url,
                               folderPath = board$folder,
                               remoteFilePath = fs::path(board$subdir, version_dir, fs::path_file(path)))
  }

  name
}



#' @rdname required_pkgs.pins_board
#' @export
required_pkgs.pins_board_labkey <- function(x, ...) {
  ellipsis::check_dots_empty()
  "Rlabkey"
}
