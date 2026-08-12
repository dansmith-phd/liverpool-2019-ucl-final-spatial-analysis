################################################################
##### Part 1: Install and load packages, pull competitions #####
################################################################

# 1. Install devtools if you don't have it already (required to install GitHub packages)
if (!require("devtools")) install.packages("devtools")

# 2. Install the StatsBomb package directly from their GitHub
devtools::install_github("statsbomb/StatsBombR")

# 3. Load the packages
library(StatsBombR)
library(tidyverse)

# Pull all free competitions available from StatsBomb
comps <- StatsBombR::FreeCompetitions()

# View the competitions to see what leagues/tournaments are available
View(comps)

################################################################
######## Part 2: Filter competitions, pull LFC matches #########
################################################################

library(jsonlite)

# 1. Read JSON strictly as a nested R list (bypasses all dataframe parsing)
matches_url <- "https://raw.githubusercontent.com/statsbomb/open-data/master/data/matches/16/4.json"
ucl_list <- jsonlite::read_json(matches_url, simplifyVector = FALSE)

# 2. Filter and extract Liverpool matches using a clean base R loop
liverpool_list <- list()

for (m in ucl_list) {
  home_team <- m$home_team$home_team_name
  away_team <- m$away_team$away_team_name
  
  # Check if Liverpool is playing
  if (home_team == "Liverpool" || away_team == "Liverpool") {
    # Extract only the clean fields we need into a standard base R dataframe
    match_info <- data.frame(
      match_id = m$match_id,
      match_date = m$match_date,
      home_team = home_team,
      away_team = away_team,
      home_score = m$home_score,
      away_score = m$away_score,
      stage = m$competition_stage$name,
      stringsAsFactors = FALSE
    )
    # Append to our list
    liverpool_list[[length(liverpool_list) + 1]] <- match_info
  }
}

# 3. Bind them into a single standard data frame
liverpool_df <- do.call(rbind, liverpool_list)

# View the final result
print(liverpool_df)


################################################################
###### Part 3: Extract match events from 18/19 UCL Final #######
################################################################

# 1. Directly pull the raw events JSON for the final (Match ID: 22912)
events_url <- "https://raw.githubusercontent.com/statsbomb/open-data/master/data/events/22912.json"
events_list <- jsonlite::read_json(events_url, simplifyVector = FALSE)

# 2. Print the total number of match events to verify it loaded successfully
cat("Successfully loaded", length(events_list), "events from the Champions League Final!")

################################################################
####### Part 4: Extract LFC players' spatial coordinates #######
################################################################

# 1. Initialize empty list to store spatial events
spatial_events_list <- list()

# 2. Loop through all events to extract spatial data for Liverpool
for (event in events_list) {
  # Check if the event has a team name and if it is Liverpool
  if (!is.null(event$team$name) && event$team$name == "Liverpool") {
    
    # Not all events have coordinates (e.g., substitutions or whistle blows don't)
    # We only want events that have a "location" field
    if (!is.null(event$location)) {
      
      # Extract coordinates (StatsBomb uses a 120x80 yard coordinate system)
      x_coord <- event$location[[1]]
      y_coord <- event$location[[2]]
      
      # Extract other key variables
      player_name <- ifelse(!is.null(event$player$name), event$player$name, "Unknown")
      event_type  <- ifelse(!is.null(event$type$name), event$type$name, "Other")
      minute      <- event$minute
      second      <- event$second
      period      <- event$period  # 1 for first half, 2 for second half
      
      # Create a temporary dataframe for this single event
      event_df <- data.frame(
        period = period,
        minute = minute,
        second = second,
        player = player_name,
        event_type = event_type,
        x = x_coord,
        y = y_coord,
        stringsAsFactors = FALSE
      )
      
      # Append to our list
      spatial_events_list[[length(spatial_events_list) + 1]] <- event_df
    }
  }
}

# 3. Bind everything into a single dataframe
liverpool_spatial <- do.call(rbind, spatial_events_list)

# 4. Print a summary of what we extracted
cat("Extracted", nrow(liverpool_spatial), "spatial events for Liverpool!\n")
print(head(liverpool_spatial))

################################################################
########## Part 5: Visualize the raw event locations ###########
################################################################

library(ggplot2)

# Create a basic spatial plot of Liverpool's event density
lfc_density_plot <- ggplot(liverpool_spatial, aes(x = x, y = y)) +
  # Draw pitch boundaries
  annotate("rect", xmin = 0, xmax = 120, ymin = 0, ymax = 80, 
           fill = "NA", color = "black", size = 1) +
  # Add halfway line
  annotate("segment", x = 60, xend = 60, y = 0, yend = 80, color = "black") +
  # Heatmap density layer
  stat_density_2d(aes(fill = ..level..), geom = "polygon", alpha = 0.5) +
  # Add the individual event points as tiny dots
  geom_point(alpha = 0.3, size = 1, color = "darkred") +
  scale_fill_gradient(low = "yellow", high = "red") +
  xlim(0, 120) +
  ylim(0, 80) +
  labs(
    title = "Liverpool Spatial Activity Density",
    subtitle = "UCL Final 2019 vs. Tottenham Hotspur",
    x = "Pitch Length (Yards)",
    y = "Pitch Width (Yards)",
    fill = "Activity Level"
  ) +
  theme_minimal()

################################################################
## Part 6: Define time windows, calculate rolling convex hulls #
################################################################

library(dplyr)

# 1. Create a helper function to calculate Convex Hull Area from x and y coordinates
calculate_hull_area <- function(x, y) {
  if (length(x) < 3) return(NA) # Need at least 3 points to form a polygon
  
  # Find the indices of the points forming the convex hull boundary
  hull_indices <- chull(x, y)
  
  # Extract boundary coordinates
  hx <- x[hull_indices]
  hy <- y[hull_indices]
  
  # Calculate area of the polygon using the Shoelace formula
  n <- length(hx)
  area <- 0.5 * abs(sum(hx[1:(n-1)] * hy[2:n] - hx[2:n] * hy[1:(n-1)]) + 
                      (hx[n] * hy[1] - hx[1] * hy[n]))
  return(area)
}

# 2. Assign each event to a 5-minute time bin (0-5 min, 5-10 min, etc.)
# We handle First Half (period 1) and Second Half (period 2) separately
liverpool_binned <- liverpool_spatial %>%
  mutate(
    time_bin = floor(minute / 5) * 5,
    # Create a unique label like "H1: 05-10" for readability
    bin_label = paste0("H", period, ": ", sprintf("%02d", time_bin), "-", sprintf("%02d", time_bin + 5))
  )

# 3. Aggregate to find the average center of gravity (centroid) and spatial area for each bin
tactical_intervals <- liverpool_binned %>%
  group_by(period, time_bin, bin_label) %>%
  summarize(
    event_count = n(),
    mean_x = mean(x, na.rm = TRUE),  # Centroid X (How high/low they are on pitch)
    mean_y = mean(y, na.rm = TRUE),  # Centroid Y (Are they leaning left/right/center)
    hull_area = calculate_hull_area(x, y),
    .groups = "drop"
  ) %>%
  # Remove bins with very few events to avoid outliers/noise
  filter(event_count >= 5, !is.na(hull_area))

# 4. View the calculated structural metrics
print(tactical_intervals)

################################################################
############ Part 7: Inspect descriptive statistics ############
################################################################

min(tactical_intervals$mean_x)
max(tactical_intervals$mean_x)
min(tactical_intervals$mean_y)
max(tactical_intervals$mean_y)
min(tactical_intervals$hull_area)
max(tactical_intervals$hull_area)
half_summary <- tactical_intervals %>%
  group_by(period) %>%
  summarize(M_x <- mean(mean_x),
            M_y <- mean(mean_y),
            M_hull_area <- mean(hull_area)) %>%
  ungroup()

################################################################
## Part 8: Define the unsupervised clustering method (k-means) #
################################################################

# 1. Select the features for clustering and scale them
# Scaling is crucial because hull_area is in thousands, while mean_x/y are under 120!
features <- tactical_intervals[, c("mean_x", "mean_y", "hull_area")]
scaled_features <- scale(features)

# 2. Set seed for reproducibility and run K-Means
set.seed(42)
kmeans_model <- kmeans(scaled_features, centers = 3, nstart = 25)

# 3. Add the cluster assignments back to our tactical intervals dataframe
tactical_intervals$cluster <- as.factor(kmeans_model$cluster)

# 4. View the typical characteristics of each tactical cluster
cluster_profile <- aggregate(
  cbind(mean_x, mean_y, hull_area, event_count) ~ cluster, 
  data = tactical_intervals, 
  FUN = mean
)

print("--- Cluster Tactical Profiles ---")
print(cluster_profile)

################################################################
############ Part 9: Visualize the spatial profiles ############
################################################################

library(ggplot2)

# 1. Create a Timeline plot of Tactical Phases
p1 <- ggplot(tactical_intervals, aes(x = time_bin, y = cluster, color = cluster)) +
  geom_line(aes(group = period), alpha = 0.4, linewidth = 1) +
  geom_point(size = 4) +
  facet_wrap(
    ~ period, 
    scales = "free_x", # Drops unused time ranges per half
    labeller = as_labeller(c(`1` = "First Half", `2` = "Second Half"))
  ) +
  scale_color_manual(values = c("1" = "#1F77B4", "2" = "#FF7F0E", "3" = "#2CA02C")) +
  scale_y_discrete(limits = c("1", "2", "3")) +
  labs(
    title = "Liverpool's Tactical Phase Transitions Over Time",
    subtitle = "5-Minute Rolling K-Means Clusters (UCL Final 2019)",
    x = "Match Minute",
    y = "Tactical Cluster",
    color = "Cluster ID"
  ) +
  theme_minimal() +
  theme(
    legend.position = "none",
    panel.grid.minor = element_blank(),
    panel.spacing = unit(1.5, "lines") # Clean spacing between halves
  )

# 2. Map Cluster Footprints on Pitch Coordinates (Mean X vs Hull Area)
p2 <- ggplot(tactical_intervals, aes(x = mean_x, y = hull_area, color = cluster)) +
  geom_point(aes(size = event_count), alpha = 0.8) +
  scale_color_manual(values = c("1" = "#1F77B4", "2" = "#FF7F0E", "3" = "#2CA02C")) +
  labs(
    title = "Cluster Profiles: Pitch Position vs. Spatial Dispersion",
    subtitle = "Higher Mean X = Deeper in Opponent Half | Higher Hull Area = More Stretched Shape",
    x = "Average Pitch Position (Yards from Own Goal)",
    y = "Convex Hull Area (Yards²)",
    size = "Events in Bin",
    color = "Cluster ID"
  ) +
  theme_minimal()

# Display plots
print(p1)
print(p2)

# Save plots
ggsave("cluster_timeline.png", plot = p1, width = 8.5, height = 5.5, dpi = 300)
ggsave("cluster_footprint.png", plot = p2, width = 8.5, height = 5.5, dpi = 300)
ggsave("lfc_density_plot.png", plot = lfc_density_plot, width = 8.5, height = 5.5, dpi = 300)
