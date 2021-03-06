# ========================================================================================================== #
# ========================================================================================================== # 
#
# Double Machine Learning for IV estimation 
#
# This script implements the double machine learning (DML) approach to conduct causal inference. The script 
# defines functions which allow to sequentially execute the different DML steps and estimate instrumental 
# variables regressions eventually. Supports weighted regressions and wild cluster bootstrapped inference. 
#
# To Do: 
# - Export DML IV WCB results 
# - Run heterogeneity analyses 
#
# ========================================================================================================== #
# ========================================================================================================== #
# Remove all objects from the workspace
rm( list=ls() )

library(plyr)
library(dplyr)
library(Matrix)
library(hdm)
library(glmnet)
library(nnet)
library(ranger)
library(rpart)
library(rpart.plot)
library(xgboost)
library(foreign)
library(haven)
library(sandwich)
library(AER)
library(clusterSEs)


# Setup ------------------------------------------------------------------------------------------------------
# Set working directory using main project path 
main_dir <- getwd() 
code_dir <- file.path(main_dir,"Code")
data_dir <- file.path(main_dir,"Data")
output_dir <- file.path(main_dir,"Output")
# Set seed 
seed.set <- 180911 
set.seed(seed.set)


# Functions --------------------------------------------------------------------------------------------------
# Multiplier bootstrap estimates 
mboot <- function(y, x, b = 1000) {
  est <- matrix(rep(NA, b*ncol(x)), nrow = b, ncol = ncol(x))  
  for (i in 1:b) {
    # Sampling weights
    set.seed(seed.set)
    wght <- sample(c(0,2), nrow(x), replace = TRUE)
    # Computing esimtates
    est[i,] <- solve(t(x)%*%(wght*as.matrix(x)))%*%(t(x)%*%(y*wght))
  }
  return(est)
}

# Clustering standard errors (traditional approach. Not needed for wild cluster bootstrap inf.) 
clust.se <- function(est.model, cluster){
  G <- length(unique(cluster))
  N <- length(cluster)
  # Reweight variance-covariance matrix by groups (clusters) and sample size, using the sandwich package 
  dfa <- (G/(G - 1)) * ((N - 1)/(N - est.model$rank))
  u <- apply(estfun(est.model),2,
             function(x) tapply(x, cluster, sum))
  vcovCL <- dfa*sandwich(est.model, meat = crossprod(u)/N)
  coeftest(est.model, vcovCL) 
}

# Partialling out (first part of DML algorithm) 
partial.out <- function(y, x, nfold = 5){
  # Setting up the table 
  columns <- c("MSE", 
               "lambda", "alpha", # For elastic net 
               "mtry", "ntree", # For random forest (ranger) 
               "iterations", "learn_rate", "max_depth", "gamma", "frac_subsample", "colsample_bytree" # For gradient boosting (xgb) 
               )  
  table.mse <- data.frame(matrix(nrow = 0, ncol = length(columns)))
  colnames(table.mse) <- columns
  
  # Split data in 80% training and 20% test data
  set.seed(seed.set)
  train <- sample(x = 1:nrow(x), size = nrow(x)*0.8) 
  x.train <- Matrix(x[train,], sparse = TRUE) 
  x.test <- Matrix(x[-train,], sparse = TRUE) 
  y.train <- y[train] 
  y.test <- y[-train] 
  
  
  #### OLS #####
  #Lin.mod <- lm(y.train~., data = data.frame(y.train, x.train[,-1]))
  # Calculating the MSE of the prediction error (removing the Intercept of x.test)
  #table.mse[1,1] <- mean((predict.lm(Lin.mod, as.data.frame(x.test[,-1])) - y.test)^2)
  #table.mse[1,2] <- "-"
  
  #### Elastic Net (incl. Lasso, Ridge) ####
  # Set step size for alpha 
  r <- 0.2
  for (i in seq(0, 1, r)) {
    # 10-fold CV to estimate tuning paramter with the lowest prediction error 
    set.seed(seed.set)
    cv.out <- cv.glmnet(x.train, y.train, family = "gaussian", nfolds = 10, alpha = i)
    # Select lambda (here: 1se instead of min.) 
    bestlam <- cv.out$lambda.1se
    # Get prediction error using the test data
    pred <- predict(cv.out, type = 'response', 
                    s = bestlam, newx = x.test)
    
    # add NA row and fill sequentially. 
    table.mse[dim(table.mse)[1]+1,] <- rep(NA, length(columns))
    if(i==0) {
      rownames(table.mse)[dim(table.mse)[1]]  <- "Ridge"
    } else if(i==1) {
      rownames(table.mse)[dim(table.mse)[1]]  <- "Lasso"
    } else {
      rownames(table.mse)[dim(table.mse)[1]]  <- paste0("Elastic Net (alpha=",i, ")")
    }
    table.mse$MSE[dim(table.mse)[1]] <- mean((pred - y.test)^2)
    table.mse$lambda[dim(table.mse)[1]] <- bestlam
    table.mse$alpha[dim(table.mse)[1]] <- i
    print(paste("glmnet using alpha =", i, "fitted."))
  }
  
  #### Random Forest ####
  # Hyperparameter tuning 
  rf.grid <- expand.grid(ntree = c(500, 1000, 2000, 5000), 
                         mtry = c(floor(sqrt(ncol(x.train))*1.5), floor(sqrt(ncol(x.train))), floor(sqrt(ncol(x.train))*0.5), 2) 
                         ) # max.depth = c(1, 2, 3, 5, 0) 
  # Start: RF grid search 
  for(i in 1:nrow(rf.grid)) {
    set.seed(seed.set)
    rf <- ranger(x = x.train, y = y.train, 
                 num.trees = rf.grid$ntree[i], 
                 mtry = rf.grid$mtry[i]) 
    pred <- predict(rf, data = x.test, type="response")$predictions 
    
    # new NA row for random forest, fill again sequentially 
    table.mse[dim(table.mse)[1]+1,] <- rep(NA,length(columns)) 
    rownames(table.mse)[dim(table.mse)[1]]  <- paste0("Random Forest (no. ", i, "/", nrow(rf.grid), ")") 
    table.mse$MSE[dim(table.mse)[1]] <- mean((pred - y.test)^2) 
    table.mse$mtry[dim(table.mse)[1]] <- rf.grid$mtry[i] 
    table.mse$ntree[dim(table.mse)[1]]<- rf.grid$ntree[i] 
    print(paste0("RF (ranger) no. ", i, "/", nrow(rf.grid), " fitted."))
  } # End: RF grid search 
  
  #### Gradient Boosting (XGB) ####
  # Hyperparameter tuning 
  xgb.grid <- expand.grid(nrounds = 20000, 
                          eta = c(0.01, 0.1, 0.3), #c(0.01, 0.05, 0.1, 0.15, 0.2, 0.3), 
                          max_depth = c(1, 2, 3, 5), #c(1, 2, 3, 5, 7), 
                          gamma = 0, 
                          subsample = 0.75, #c(0.75, 1),
                          colsample_bytree = 0.8, #c(0.7, 0.8, 0.9, 1), 
                          opt.trees = NA,               # save results here 
                          min.RMSE = NA                 # save results here 
                          )
  # Start: XGB grid search 
  for(i in 1:nrow(xgb.grid)) {
    # Create parameter list
    params <- list(nrounds = xgb.grid$nrounds[i], 
                   eta = xgb.grid$eta[i], 
                   max_depth = xgb.grid$max_depth[i], 
                   gamma = xgb.grid$gamma[i], 
                   subsample = xgb.grid$subsample[i], 
                   colsample_bytree = xgb.grid$colsample_bytree[i]) 
    
    # Tune model using 5-fold cv 
    set.seed(seed.set)
    xgb.tune <- xgb.cv(params = params, 
                       data = x.train, 
                       label = y.train, 
                       nrounds = params$nrounds, 
                       nfold = 5, 
                       objective = "reg:squarederror",  # for regression models 
                       early_stopping_rounds = 100, # stop if no improvement for 100 consecutive trees 
                       print_every_n = 500, 
                       eval_metric = "rmse")
    
    # Save results (number of trees/iterations and training error) to grid 
    xgb.grid$opt.trees[i] <- which.min(xgb.tune$evaluation_log$test_rmse_mean)
    xgb.grid$min.RMSE[i] <- min(xgb.tune$evaluation_log$test_rmse_mean)
  } # End: XGB grid search 
  
  # Learn final model with optimal parameters on whole training data 
  # Create parameter list 
  params <- list(nrounds = xgb.grid$opt.trees[which.min(xgb.grid$min.RMSE)], 
                 eta = xgb.grid$eta[which.min(xgb.grid$min.RMSE)], 
                 max_depth = xgb.grid$max_depth[which.min(xgb.grid$min.RMSE)], 
                 gamma = xgb.grid$gamma[which.min(xgb.grid$min.RMSE)], 
                 subsample = xgb.grid$subsample[which.min(xgb.grid$min.RMSE)], 
                 colsample_bytree = xgb.grid$colsample_bytree[which.min(xgb.grid$min.RMSE)]) 
  # Train final model w/ cross-validated hyperparameters 
  set.seed(seed.set)
  xgb.trained <- xgb.train(params = params, 
                           data = xgb.DMatrix(x.train, 
                                              label = y.train), 
                           nrounds = params$nrounds, 
                           objective = "reg:squarederror",  # for regression models 
                           eval_metric = "rmse") 
  # Predict test data using trained final model 
  pred <- predict(xgb.trained, newdata = x.test) 
  
  # new NA row for extreme gradient boosting, fill again sequentially 
  table.mse[dim(table.mse)[1]+1,] <- rep(NA,length(columns)) 
  rownames(table.mse)[dim(table.mse)[1]]  <- paste0("Extreme Gradient Boosting") 
  table.mse$MSE[dim(table.mse)[1]] <- mean((pred - y.test)^2) 
  table.mse$iterations[dim(table.mse)[1]] <- params$nrounds 
  table.mse$learn_rate[dim(table.mse)[1]]<- params$eta 
  table.mse$max_depth[dim(table.mse)[1]]<- params$max_depth 
  table.mse$gamma[dim(table.mse)[1]]<- params$gamma 
  table.mse$frac_subsample[dim(table.mse)[1]]<- params$subsample 
  table.mse$colsample_bytree[dim(table.mse)[1]]<- params$colsample_bytree 
  print("XGB fitted.") 
  
  
  # Benchmarking: Select best method based on OOB MSE 
  # (Identify best method directly using method-specific tuning parameters): 
  # Prepare data for (nfold) cross-fitting 
  set.seed(seed.set)
  foldid <- rep.int(1:nfold, times = ceiling(nrow(x)/nfold))[sample.int(nrow(x))]
  I <- split(1:nrow(x), foldid)
  # Code up object to store residuals 
  til <- rep(NA, nrow(x))
  # Compute cross-fitted residuals 
  for(b in 1:length(I)){
    print(paste0("Compute residuals: Fold ", b, "/", length(I)))
    set.seed(seed.set)
    # Elnet 
    if (!is.na(table.mse$lambda[which.min(table.mse$MSE)])) { 
      opt.alpha <- table.mse$alpha[which.min(table.mse$MSE)]
      opt.lambda <- table.mse$lambda[which.min(table.mse$MSE)]
      best.mod <- glmnet(x[-I[[b]],], y[-I[[b]]], 
                         alpha = opt.alpha, 
                         lambda = opt.lambda)
      hat <- predict(best.mod, type = 'response', 
                       s = opt.lambda, 
                       newx = x[I[[b]],])
      }
    # RF 
    if (!is.na(table.mse$mtry[which.min(table.mse$MSE)])) { 
      opt.mtry <- table.mse$mtry[which.min(table.mse$MSE)] 
      opt.ntree <- table.mse$ntree[which.min(table.mse$MSE)] 
      best.mod <- ranger(x = x[-I[[b]],], y = y[-I[[b]]], 
                         num.trees = opt.ntree, 
                         mtry = opt.mtry) 
      hat <- predict(best.mod, data = x[I[[b]],], type="response")$predictions 
      }
    # XGBoost 
    # (No need to specify hyperparameters again, as only the best xgb model is written to table. 
    # Hence, its hyperparameters can still be directly called from params-list.) 
    if (!is.na(table.mse$learn_rate[which.min(table.mse$MSE)])) { 
      best.mod <- xgb.train(params = params, 
                            data = xgb.DMatrix(x[-I[[b]],], 
                                               label = y[-I[[b]]]), 
                            nrounds = params$nrounds, 
                            objective = "reg:squarederror",  # for regression models 
                            eval_metric = "rmse") 
      hat <- predict(best.mod, newdata = x[I[[b]],]) 
      }
    til[I[[b]]] <- (y[I[[b]]] - hat) 
    }
  return(list("til" = til, 
              "table.mse" = table.mse))
}

# Start ==================================================================================================== # 
# Load data --------------------------------------------------------------------------------------------------
data.share <- read_dta(file.path(data_dir,"share_rel6-1-1_data3.dta")) 

# Some additional pre-processing (select relevant variables, drop missings, recode variables)
ctrend_1 <- paste0("trend1cntry_", 1:length(unique(data.share$country))) 
ctrend_2 <- paste0("trend2cntry_", 1:length(unique(data.share$country))) 
ctrend_3 <- paste0("trend3cntry_", 1:length(unique(data.share$country))) 
var.select <- c("eurodcat", "chyrseduc", "t_compschool", 
                "country", "chbyear", "sex", "chsex", "int_year", "agemonth", "yrseduc", 
                ctrend_1, ctrend_2, #ctrend_3, 
                "normchbyear", "w_ch") 

data.share <- 
  data.share %>% 
  select(var.select) %>% 
  na.omit() %>% 
  filter(normchbyear %in% c(-10:-1,1:10)) %>% 
  mutate(eurodcat = as.numeric(eurodcat))

# Main sample ================================================================================================
# Implement machine learning methods to get residuals --------------------------------------------------------
# Define outcome y, treatment d, and instrumental variable z  
y <- as.matrix(data.share[,"eurodcat"]) 
d <- as.matrix(data.share[,"chyrseduc"]) 
z <- as.matrix(data.share[,"t_compschool"]) 

# Code up formula for all models 
# Use this model for testing only (so that code runs faster)
#x <- model.matrix(~(-1 + factor(country) + factor(chbyear) + factor(int_year)), 
#                  data=data.share)
# Basic model for actual preliminary analyses 
x.formula <- as.formula(paste0("~(-1 + factor(country) + factor(chbyear) + factor(sex) + factor(chsex) + factor(int_year) + poly(agemonth,2) + poly(yrseduc,2) + ", 
                               paste(ctrend_1, collapse = " + "), " + ", 
                               paste(ctrend_2, collapse = " + "), #" + ", 
                               #paste(ctrend_3, collapse = " + "), 
                               ")"))
x <- sparse.model.matrix(x.formula, 
                         data=data.share) 

# Start: partialling out -------------------------------------------------------------------------------------
# (also check running time and save results) 
start_time <- Sys.time()
ytil <- partial.out(y, x)
y_end_time <- Sys.time() 
y_end_time - start_time 
write.csv2(as.data.frame(ytil$til),
           file=file.path(output_dir,'y_til.csv'),
           row.names=FALSE)
write.csv2(as.data.frame(ytil$table.mse),
           file=file.path(output_dir,'y_tablemse.csv'),
           row.names=FALSE)
dtil <- partial.out(d, x)
d_end_time <- Sys.time() 
d_end_time - start_time 
write.csv2(as.data.frame(dtil$til),
           file=file.path(output_dir,'d_til.csv'),
           row.names=FALSE)
write.csv2(as.data.frame(dtil$table.mse),
           file=file.path(output_dir,'d_tablemse.csv'),
           row.names=FALSE)
ztil <- partial.out(z, x) 
z_end_time <- Sys.time() 
z_end_time - start_time 
write.csv2(as.data.frame(ztil$til),
           file=file.path(output_dir,'z_til.csv'),
           row.names=FALSE)
write.csv2(as.data.frame(ztil$table.mse),
           file=file.path(output_dir,'z_tablemse.csv'),
           row.names=FALSE)

# Start: Inference -------------------------------------------------------------------------------------------
# IV regression using residuals along with wild cluster bootstrap inference 
# code up dataframe data.til, containing all residuals from partialling out 
data.til <- data.frame(y = as.numeric(ytil$til), 
                       d = as.numeric(dtil$til), 
                       z = as.numeric(ztil$til), 
                       cluster = as.numeric(factor(data.share$country)), 
                       wght = data.share$w_ch)
ivfit <- ivreg(formula = y ~ d | z, 
               weights = wght, 
               data = data.til)
summ.ivfit <- summary(ivfit)
summ.ivfit #$coefficients[2,3]
set.seed(seed.set)
ivfit.clust <- cluster.wild.ivreg(ivfit, 
                                  dat = data.til, 
                                  cluster = ~ cluster, 
                                  ci.level = 0.95, 
                                  boot.reps = 1000, 
                                  seed = seed.set)
ivfit.clust 

# Heterogeneity by gender ====================================================================================
# To Do: Estimate DML IV effects for fathers/mothers, parents of sons/daughters 
