import glob
import logging
import os

import xarray as xr

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    logging.getLogger("gribapi.bindings").setLevel(logging.WARN)

    var_dirs = []
    for hemi in ["north", "south"]:
        var_dirs.extend(glob.glob(os.path.join("data/cmip6.*/month", hemi, "*")))
        # for src_dirs in glob.glob(os.path.join("data/cmip6.*/*")):
        #    if src_dirs.split(os.sep)[-1] in ["day", "month"]:
        #        continue
        #    var_dirs.append(os.path.join(src_dirs, hemi))

    for dir in var_dirs:
        dfs = glob.glob("{}/*.nc".format(dir))

        if len(dfs) == 0:
            logging.warning("No datafiles available")
            continue
        logging.info("Directory: {} - {} files".format(dir, len(dfs)))
        logging.debug(dfs)
        dss = []
        try:
            dss.append(xr.open_mfdataset(dfs))
        except ValueError:
            for df in dfs:
                dss.append(xr.open_dataset(df))

        for ds in dss:
            da = getattr(ds, list(ds.data_vars)[0]).isnull().sum(["lat", "lon"]).compute()
            da = da.groupby("time.year").sum()
            years = list(da.where(da > 0., drop=True).squeeze().year.values)

            year_files = set(["{}.nc".format(el) for el in years])

            for ydf in year_files:
                df = os.path.join(dir, ydf)
                logging.warning("Removing {}".format(df))
                # os.unlink(df)
