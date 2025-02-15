.processFieldDefs <- function(fields) {
    
    fields <- as.integer(fields)
    fields <- split(fields, rep(1:3, by = length(fields)/3))
    #fields[[3]] <- format(as.hexmode(fields[[3]]), width = 2)
    fields[[3]] <- unlist(
        lapply(fields[[3]], function(x) { 
            FITfileR:::.binaryToInt(intToBits(x)[1:4])  
        })
    )
    names(fields) = c('field_def_num', 'size', 'base_type')
    return(fields)
}

.processDevFieldDefs <- function(fields) {
    
    fields <- as.integer(fields)
    fields <- split(fields, rep(1:3, by = length(fields)/3))
    names(fields) = c('field_num', 'size', 'developer_idx')
    return(fields)
}

.readMessage_definition <- function(con, message_header) {
    
    reserved <- readBin(con = con, what = "raw", n = 1, size = 1)
    architecture <- ifelse(readBin(con = con, what = "int", n = 1, size = 1),
                           "big", "little")
    global_message_num <- readBin(con = con, what = "int", n = 1, size = 2,
                                  endian = architecture, signed = FALSE)
    n_fields <- readBin(con = con, what = "int", n = 1, size = 1, signed = FALSE)
    field_definition <- .processFieldDefs(
        readBin(con = con, what = "raw", n = 3 * n_fields, size = 1, signed = FALSE)
    )
    if(hasDeveloperData(message_header)){
        ## do something with the developer fields
        n_dev_fields <- readBin(con = con, what = "int", n = 1, size = 1, signed = FALSE)
        dev_fields_raw <- readBin(con = con, what = "raw", n = 3 * n_dev_fields, size = 1, signed = FALSE)
        dev_field_definition <- .processDevFieldDefs(
            dev_fields_raw
        )
    } else {
        dev_field_definition = NULL
    }
    
    message <- new("FitDefinitionMessage",
                   header = message_header,
                   is_little_endian = (architecture == "little"),
                   global_message_number = global_message_num,
                   field_defs = field_definition,
                   dev_field_defs = dev_field_definition
    )
    
    return(message)
}

## should be refactored!!!
## currently just copy/paste from .readMessage_data()
.readMessage_devdata <- function(con, header, definition, developer_msgs) {
    
    fieldDefs <- fieldDefinition(definition)
    ## we add 1 here because R indexing starts at 1 not 0
    fieldTypes <- fieldDefs$base_type + 1
    sizes <- fieldDefs$size
    devFieldDefs <- devFieldDefinition(definition)
    
    if(definition@is_little_endian) { endian <- "little" } else { endian <- "big" }
    
    message <- vector(mode = "list", length = length(fieldTypes))
    for(i in seq_along(fieldTypes)) {
        
        if (fieldTypes[i] %in% seq_along(data_type_lookup)) {
            
            readInfo <- data_type_lookup[[ fieldTypes[i] ]] 
            
            ## a single field can have an array of values 
            single_size <- prod(as.integer(readInfo[3:4]))
            
            n_values <- sizes[i] %/% single_size
            if(fieldTypes[i] == 8L) {
                suppressWarnings(
                    message[[i]] <- readChar(con = con, nchars = n_values, useBytes = TRUE)
                )
            } else {
                for(j in seq_len( n_values ) ) {
                    
                    dat <- readBin(con, what = readInfo[[1]], signed = readInfo[[2]],
                                   size = readInfo[[3]], n = readInfo[[4]], 
                                   endian = endian)
                    
                    ## if we have unsigned ints, turn the bits into a numeric
                    if(fieldTypes[i] %in% c(7L, 13L)) {
                        if(definition@is_little_endian) {
                            bits <- as.logical(rawToBits(dat[1:4]))
                        } else {
                            bits <- as.logical(rawToBits(dat[4:1]))
                        }
                        dat <- sum(2^(.subset(0:31, bits)))
                    } else if (fieldTypes[i] == 14L) { ## maybe this conversion should be done when reading?
                        dat <- as.integer(dat)
                    } else if (fieldTypes[i] %in% c(15L, 16L)) {
                        dat <- .rawToInt64(raw = dat)
                    }
                    
                    if(n_values == 1) {
                        message[[i]] <- c(message[[i]], dat)
                    } else { ## put multiple values in a list, otherwise the tibble has columns with different lengths.
                        if(j == 1) {
                            message[[i]] <- list(dat)
                        } else {
                            message[[i]][[1]] <- c(message[[i]][[1]], dat)
                        }
                    }
                }
            }
        } else {
            readBin(con, what = "integer", size = 1, n = sizes[i])
            message[[i]] <- 0
        }
    }
    
    k <- length(fieldTypes)
    
    dev_data <- vector(mode = "list", length = length(devFieldDefs$field_num))
    dev_data_mesg_defs <- vector(mode = "list", length = length(devFieldDefs$field_num))
    ## loop over the developer fields
    for(i in seq_along(devFieldDefs$field_num)) {
        
        ## index within the set of developer messages
        idx <- devFieldDefs$developer_idx[i] + 1
        size <- devFieldDefs$size[i]
        field_num <- devFieldDefs$field_num[i] + 1
        
        developer_msg <- developer_msgs[[idx]]$messages[[field_num]]
        dev_data_mesg_defs[[i]] <- developer_msg
        dm_fieldDefs <- fieldDefinition(developer_msg)
        
        base_type <- developer_msg@fields[[which(dm_fieldDefs$field_def_num == 2)]] %>% 
            as.hexmode() %>% format(width = 2)
        readInfo <- data_type_lookup[[ base_type ]] 
        
        ## a single field can have an array of values 
        single_size <- prod(as.integer(readInfo[3:4]))
        
        n_values <- size %/% single_size
        if(base_type == 8L) {
            suppressWarnings(
                dev_data[[i]] <- readChar(con = con, nchars = n_values, useBytes = TRUE)
            )
        } else {
            for(j in seq_len( n_values ) ) {
                
                dat <- readBin(con, what = readInfo[[1]], signed = readInfo[[2]],
                               size = readInfo[[3]], n = readInfo[[4]], 
                               endian = endian)
                
                ## if we have unsigned ints, turn the bits into a numeric
                if(base_type %in% c(7L, 13L)) {
                    if(definition@is_little_endian) {
                        bits <- as.logical(rawToBits(dat[1:4]))
                    } else {
                        bits <- as.logical(rawToBits(dat[4:1]))
                    }
                    dat <- sum(2^(.subset(0:31, bits)))
                } else if (base_type == 14L) { ## maybe this conversion should be done when reading?
                    dat <- as.integer(dat)
                } else if (base_type %in% c(15L, 16L)) {
                    dat <- .rawToInt64(raw = dat)
                }
                
                if(n_values == 1) {
                    dev_data[[i]] <- c(dev_data[[i]], dat)
                } else { ## put multiple values in a list, otherwise the tibble has columns with different lengths.
                    if(j == 1) {
                        dev_data[[i]] <- list(dat)
                    } else {
                        dev_data[[i]][[1]] <- c(dev_data[[i]][[1]], dat)
                    }
                }
            }
        }
        
    }
    
    res <- new("FitDataMessageWithDevData",
               header = header,
               definition = definition,
               fields = message,
               dev_fields = dev_data,
               dev_field_details = dev_data_mesg_defs)
}

.readMessage_data <- function(con, header, definition) {
    
    fieldDefs <- fieldDefinition(definition)
    ## we add 1 here because R indexing starts at 1 not 0
    fieldTypes <- fieldDefs$base_type + 1
    sizes <- fieldDefs$size
    
    if(any(fieldTypes > length(data_type_lookup))) {
        stop("Unable to read data message.\n",
             "Unknown field types detected.")
    }
    
    if(definition@is_little_endian) { endian <- "little" } else { endian <- "big" }
    
    message <- vector(mode = "list", length = length(fieldTypes))
    for(i in seq_along(fieldTypes)) {
        
        readInfo <- data_type_lookup[[ fieldTypes[i] ]]
        
        ## a single field can have an array of values 
        single_size <- prod(readInfo$size, readInfo$n)
        
        n_values <- sizes[i] %/% single_size
        if(fieldTypes[i] == 8L) {
            suppressWarnings(
                message[[i]] <- readChar(con = con, nchars = n_values, useBytes = TRUE)
            )
        } else {
            for(j in seq_len( n_values ) ) {
                
                dat <- readBin(con, what = readInfo$what, signed = readInfo$signed,
                               size = readInfo$size, n = readInfo$n, 
                               endian = endian)
                
                ## if we have unsigned ints, turn the bits into a numeric
                if(fieldTypes[i] == 7L || fieldTypes[i] == 13L) {
                    if(definition@is_little_endian) {
                        bits <- as.logical(rawToBits(dat[1:4]))
                    } else {
                        bits <- as.logical(rawToBits(dat[4:1]))
                    }
                    dat <- sum(2^(.subset(0:31, bits)))
                } else if (fieldTypes[i] == 14L) { ## maybe this conversion should be done when reading?
                    dat <- as.integer(dat)
                } else if (fieldTypes[i] %in% c(15L, 16L)) {
                    dat <- .rawToInt64(raw = dat)
                }
                
                if(n_values == 1) {
                    message[[i]] <- c(message[[i]], dat)
                } else { ## put multiple values in a list, otherwise the tibble has columns with different lengths.
                    if(j == 1) {
                        message[[i]] <- list(dat)
                    } else {
                        message[[i]][[1]] <- c(message[[i]][[1]], dat)
                    }
                }
            }
        }
    }
    
    if(hasDeveloperData(definition)) {
        dev_data <- .readMessage_devdata(con, definition@dev_field_defs, definition@is_little_endian)
        names(dev_data) <- devFieldDefinition(definition)$field_def_num
        
        res <- new("FitDataMessageWithDevData",
                   header = header,
                   definition = definition,
                   fields = message,
                   dev_fields = dev_data
        )
    } else {
        res <- new("FitDataMessage",
                   header = header,
                   definition = definition,
                   fields = message
        )
    }
    
    return(res)
}

.readMessage_dev_data_id <- function(con, header, definition, devMessages) {
    tmp <- .readMessage_data(con = con, header = header, definition = definition)
    dev_data_idx_idx <- which(tmp@definition@field_defs$field_def_num == 3)
    manufacturer_id_idx <- which(tmp@definition@field_defs$field_def_num == 2)
    
    ## add 1 becuase FIT file indices are 0-based
    idx <- tmp@fields[[ dev_data_idx_idx ]]+1
    
    devMessages[[idx]] <- list()
    devMessages[[idx]][["messages"]] <- list()
    
    return(devMessages)
}

.readMessage_dev_data_field_definition <- function(con, header, definition, devMessages) {
    msg <- .readMessage_data(con = con, header = header, definition = definition)
    developer_idx <- which(msg@definition@field_defs$field_def_num == 0)
    field_idx <- which(msg@definition@field_defs$field_def_num == 1)
    
    ## add 1 becuase FIT file indices are 0-based
    dev_data_idx <- as.integer(msg@fields[[ developer_idx ]]) + 1
    field_number <- as.integer(msg@fields[[ field_idx ]]) + 1
    
    devMessages[[ dev_data_idx ]][[ "messages" ]][[ field_number ]] <- msg
    return(devMessages)
}
